public import AppKit
import CmuxNextWakeups
import QuartzCore

/// Scripted performance run on a live Home window (MessagesLab `Bench.swift`
/// ported): `fling20k`, `jumpToOldestAndBack`, `send20`, `resizeDrag`. Every
/// step waits on a signal (a display frame, a page joining); nothing sleeps.
/// Frame intervals are display-link timestamps; a hitch is an interval over
/// 1.5 refresh periods. Main-thread work per frame is the run loop's busy time
/// between two frames (Core Animation's commit included); CPU is the main
/// thread's CPU time over the same span. `completion` gets one JSON object.
public enum HomeBench {
    private static var driver: HomeBenchDriver?

    public static func run(view: HomeView, window: NSWindow, completion: @escaping @MainActor (String) -> Void) {
        let driver = HomeBenchDriver(view: view, window: window) { json in
            HomeBench.driver = nil
            completion(json)
        }
        Self.driver = driver
        driver.begin()
    }
}

final class HomeBenchDriver {
    let view: HomeView
    let window: NSWindow
    var transcript: TranscriptView { view.transcript }
    private let finish: @MainActor (String) -> Void
    private var result: [String: Any] = [:]
    private var step: ((FrameTick) -> Void)?
    private var client: FrameClient?
    private var lastTimestamp = 0.0
    private var busyStart = 0.0, busyAccum = 0.0
    private var cpuStart = 0.0, cpuAccum = 0.0
    private var observers: [CFRunLoopObserver] = []
    private let started = HomeBenchProbe.now()
    /// HOME_BENCH_FRAMELOG=1 prints every frame with more than 5 ms of main-thread work.
    private let frameLog = ProcessInfo.processInfo.environment["HOME_BENCH_FRAMELOG"] != nil

    init(view: HomeView, window: NSWindow, finish: @escaping @MainActor (String) -> Void) {
        self.view = view
        self.window = window
        self.finish = finish
    }

    func begin() {
        result["load_before"] = HomeBenchProbe.load1()
        result["cpuCores"] = ProcessInfo.processInfo.activeProcessorCount
        // busy = wake-up to sleep; the sleep observer runs last, after Core Animation's commit
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) {
            [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.busyStart = HomeBenchProbe.now()
                self?.cpuStart = HomeBenchProbe.threadCPU()
            }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) {
            [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.busyStart > 0 else { return }
                self.busyAccum += HomeBenchProbe.now() - self.busyStart
                self.cpuAccum += HomeBenchProbe.threadCPU() - self.cpuStart
                self.busyStart = 0
            }
        }
        if let wake, let sleep {
            CFRunLoopAddObserver(CFRunLoopGetMain(), wake, .commonModes)
            CFRunLoopAddObserver(CFRunLoopGetMain(), sleep, .commonModes)
            observers = [wake, sleep]
        }
        onEachFrame { [weak self] _ in
            guard let self, self.transcript.history.count > 0, self.transcript.isPinned else { return }
            self.result["launchToBottomInteractiveMs"] = HomeBenchStats.ms(HomeBenchProbe.now() - self.started)
            self.result["historyTotal"] = self.transcript.source?.newestSeq ?? 0
            self.result["windowMessagesAtLaunch"] = self.transcript.history.count
            self.result["residentMBAtLaunch"] = HomeBenchProbe.residentMB()
            self.fling()
        }
    }

    /// Measures frames until `run` returns false.
    private func scenario(_ name: String, _ run: @escaping (FrameTick, Int) -> Bool, then: @escaping () -> Void) {
        let stats = HomeBenchStats()
        lastTimestamp = 0
        var frame = 0
        onEachFrame { [weak self] tick in
            guard let self else { return }
            if let refresh = tick.refreshInterval, refresh > 0 { stats.refresh = refresh }
            if self.lastTimestamp > 0, tick.refreshInterval != nil {
                stats.intervals.append(tick.timestamp - self.lastTimestamp)
                stats.busy.append(self.busyAccum)
                stats.cpu.append(self.cpuAccum)
                if self.frameLog, self.busyAccum > 0.005 {
                    let p = self.transcript.perf
                    FileHandle.standardError.write(Data(String(format: "%@ busy %.2f cpu %.2f chunk %.2f render %.2f (measure %.2f prefetch %.2f place %.2f commit %.2f) interval %.2f\n",
                        name, self.busyAccum * 1000, self.cpuAccum * 1000, p.chunk, p.render, p.measure, p.prefetch,
                        p.place, p.commit,
                        (tick.timestamp - self.lastTimestamp) * 1000).utf8))
                }
            }
            self.transcript.perf.reset()
            self.busyAccum = 0
            self.cpuAccum = 0
            self.lastTimestamp = tick.timestamp
            frame += 1
            guard !run(tick, frame) else { return }
            var json = stats.json()
            json["residentMBAfter"] = HomeBenchProbe.residentMB()
            json["maxLiveRowLayers"] = self.transcript.maxLiveLayers
            json["windowMessages"] = self.transcript.history.count
            self.result[name] = json
            then()
        }
    }

    private func fling() {
        let target = 20_000
        let startSeq = transcript.seqAtTop
        var goingUp = true
        // about one screen per frame at 120 Hz
        let speed: CGFloat = 800
        scenario("fling20k", { [weak self] _, _ in
            guard let self else { return false }
            if goingUp {
                self.transcript.scroll(by: speed)
                let traversed = startSeq - self.transcript.seqAtTop
                if traversed >= target || (!self.transcript.history.hasOlder && self.transcript.seqAtTop <= self.transcript.history.firstSeq) {
                    goingUp = false
                    self.result["fling20kMessagesTraversed"] = traversed
                }
                return true
            }
            self.transcript.scroll(by: -speed)
            return !self.transcript.isPinned
        }, then: { [weak self] in
            guard let self else { return }
            let counts = self.transcript.rasterizer.counts
            self.result["drawsOnMainTotal"] = counts.main
            self.result["drawsInBackgroundTotal"] = counts.background
            self.result["placeholderRowFrames"] = self.transcript.placeholdersShown
            self.jumps()
        })
    }

    private func jumps() {
        var phase = 0
        var t0 = 0.0, settle = 0
        scenario("jumpToOldestAndBack", { [weak self] tick, _ in
            guard let self else { return false }
            switch phase {
            case 0:
                t0 = tick.timestamp
                phase = 1
                self.transcript.jumpToOldest { phase = 2 }
            case 1: break
            case 2:
                self.result["jumpToOldestSettledMs"] = HomeBenchStats.ms(tick.timestamp - t0)
                self.result["residentMBAfterJumpOldest"] = HomeBenchProbe.residentMB()
                self.result["oldestSeqOnScreen"] = self.transcript.seqAtTop
                phase = 3
                settle = 30
            case 3:
                settle -= 1
                if settle == 0 {
                    t0 = tick.timestamp
                    phase = 4
                    self.transcript.jumpToNewest { phase = 5 }
                }
            case 4: break
            default:
                if settle == 0 { self.result["jumpToNewestSettledMs"] = HomeBenchStats.ms(tick.timestamp - t0) }
                settle += 1
                return settle < 30
            }
            return true
        }, then: { [weak self] in
            self?.result["residentMBAfterJumpBack"] = HomeBenchProbe.residentMB()
            self?.sends()
        })
    }

    private func sends() {
        var sent = 0, wait = 0, idleFrames = 0
        var perSend: [Double] = []
        let committed0 = transcript.committer.committed
        let other = transcript.source?.participants.first { !$0.isMe }?.id ?? ""
        let newest0 = transcript.source?.newestSeq ?? 0
        scenario("send20", { [weak self] _, _ in
            guard let self else { return false }
            if sent >= 20 {
                // until every reply arrived and every motion ended
                let replies = (newest0..<(self.transcript.history.lastSeq + 1)).count { seq in
                    seq > newest0 && seq >= self.transcript.history.firstSeq
                        && self.transcript.history[seq - self.transcript.history.firstSeq].authorID == other
                }
                let busy = !self.transcript.typingIDs.isEmpty || !self.transcript.flights.isEmpty
                    || !self.transcript.rowMotion.isEmpty
                idleFrames = busy || replies < 20 ? 0 : idleFrames + 1
                wait += 1
                return idleFrames < 10 && wait < 2400
            }
            if wait > 0 { wait -= 1; return true }
            sent += 1
            let start = HomeBenchProbe.now()
            self.view.composer.text = "Bench message \(sent)"
            self.view.composer.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            perSend.append(HomeBenchStats.ms(HomeBenchProbe.now() - start))
            wait = 12
            return true
        }, then: { [weak self] in
            guard let self else { return }
            self.result["send20WorkPerSendMs"] = perSend
            self.result["send20CAAnimationsCommitted"] = self.transcript.committer.committed - committed0
            self.resize()
        })
    }

    private func resize() {
        let origin = window.frame
        let frames = 240
        scenario("resizeDrag", { [weak self] _, n in
            guard let self else { return false }
            let x = Double(n) / Double(frames)
            let w = origin.width + 220 * sin(x * .pi)
            let h = origin.height - 160 * sin(x * .pi)
            self.window.setFrame(NSRect(x: origin.maxX - w, y: origin.minY, width: w, height: h), display: true)
            return n < frames
        }, then: { [weak self] in
            guard let self else { return }
            self.window.setFrame(origin, display: true)
            self.done()
        })
    }

    private func done() {
        step = nil
        client?.deactivate()
        client = nil
        for observer in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observers.removeAll()
        let loadBefore = result["load_before"] as? Double ?? 999
        result["load_after"] = HomeBenchProbe.load1()
        result["loadValid"] = loadBefore < 36
        result["idle"] = ["pagingClientActive": transcript.pagingClient.isActive,
                          "cleanupScheduled": transcript.cleanup.isScheduled]
        let data = (try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        finish(String(decoding: data, as: UTF8.self))
    }

    private func onEachFrame(_ body: @escaping (FrameTick) -> Void) {
        step = body
        guard client == nil else { return }
        let made = FrameClient(owner: "home.bench", isAnimation: false, on: FrameScheduler.forWindow(window)) { [weak self] tick in
            self?.step?(tick)
            return self?.step != nil
        }
        client = made
        made.activate()
    }
}
