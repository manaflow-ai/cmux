import Foundation
import Testing
import CmuxBrowser

@MainActor
@Suite("Browser engine warmup")
struct BrowserEngineWarmupTests {
    @MainActor
    final class FakeEngine: BrowserEngineWarming {
        var availability: BrowserEngineAvailability = .available
        var isRunning = false
        private(set) var preloads = 0
        private(set) var starts: [BrowserEngineWarmupReason] = []

        func preload() { preloads += 1 }

        func warmStart(reason: BrowserEngineWarmupReason) async {
            starts.append(reason)
            isRunning = true
        }
    }

    @MainActor
    final class ManualTimer: BrowserEngineWarmupTimer {
        private(set) var delay: Duration?
        private var fire: (@MainActor () -> Void)?
        var isScheduled: Bool { fire != nil }

        func schedule(after delay: Duration, _ fire: @escaping @MainActor () -> Void) {
            self.delay = delay
            self.fire = fire
        }

        func cancel() {
            delay = nil
            fire = nil
        }

        func fireNow() {
            let pending = fire
            fire = nil
            pending?()
        }
    }

    @MainActor
    final class FakeInput: BrowserEngineWarmupInputMonitoring {
        var isTrackingMenu = false
        private(set) var isMonitoring = false
        private var onInput: (@MainActor () -> Void)?
        private var onMenuEnd: (@MainActor () -> Void)?

        func start(onInput: @escaping @MainActor () -> Void, onMenuTrackingEnd: @escaping @MainActor () -> Void) {
            isMonitoring = true
            self.onInput = onInput
            onMenuEnd = onMenuTrackingEnd
        }

        func stop() {
            isMonitoring = false
            onInput = nil
            onMenuEnd = nil
        }

        func input() { onInput?() }
        func menuEnded() { onMenuEnd?() }
    }

    @MainActor
    final class Harness {
        let engine = FakeEngine()
        let input = FakeInput()
        let idle = ManualTimer()
        let giveUp = ManualTimer()
        var clock: TimeInterval = 100
        lazy var warmup = BrowserEngineWarmup(
            engine: engine,
            input: input,
            idleTimer: idle,
            giveUpTimer: giveUp,
            now: { [unowned self] in self.clock }
        )

        func settle() async {
            for _ in 0..<10 { await Task.yield() }
        }
    }

    @Test("Nothing loads or monitors input until a page is likely")
    func lazyUntilLikely() {
        let h = Harness()
        _ = h.warmup
        #expect(h.engine.preloads == 0)
        #expect(!h.input.isMonitoring)
        #expect(!h.idle.isScheduled)
        #expect(h.warmup.phase == .idle)
    }

    @Test("Starts once the app was idle for the quiet period")
    func startsWhenIdle() async {
        let h = Harness()
        h.warmup.engineLikely(.restoredPage)
        #expect(h.engine.preloads == 1)
        #expect(h.input.isMonitoring)
        #expect(h.idle.delay == .milliseconds(750))
        #expect(h.giveUp.delay == .seconds(60))

        h.clock += 0.75
        h.idle.fireNow()
        #expect(h.warmup.phase == .starting)
        #expect(!h.input.isMonitoring)
        #expect(!h.giveUp.isScheduled)
        await h.settle()
        #expect(h.engine.starts == [.restoredPage])
        #expect(h.warmup.phase == .started)
    }

    @Test("Input during the quiet period re-arms for the rest of a new one")
    func inputDefersStart() async {
        let h = Harness()
        h.warmup.engineLikely(.palette)
        h.clock += 0.5
        h.input.input()
        h.clock += 0.25
        h.idle.fireNow()
        #expect(h.warmup.phase == .waiting)
        #expect(h.engine.starts.isEmpty)
        #expect(h.idle.delay == .milliseconds(500))

        h.clock += 0.5
        h.idle.fireNow()
        await h.settle()
        #expect(h.engine.starts == [.palette])
    }

    @Test("A tracking menu defers the start until it ends and the app is idle again")
    func menuTrackingDefersStart() async {
        let h = Harness()
        h.warmup.engineLikely(.newPageMenu)
        h.input.isTrackingMenu = true
        h.clock += 1
        h.idle.fireNow()
        #expect(h.warmup.phase == .waiting)
        #expect(!h.idle.isScheduled)

        h.input.isTrackingMenu = false
        h.input.menuEnded()
        #expect(h.idle.delay == .milliseconds(750))
        h.clock += 0.75
        h.idle.fireNow()
        await h.settle()
        #expect(h.engine.starts == [.newPageMenu])
    }

    @Test("Gives up when the app never goes idle, leaving the engine lazy")
    func givesUp() async {
        let h = Harness()
        h.warmup.engineLikely(.browserPage)
        h.giveUp.fireNow()
        #expect(h.warmup.phase == .abandoned)
        #expect(!h.input.isMonitoring)
        #expect(!h.idle.isScheduled)
        await h.settle()
        #expect(h.engine.starts.isEmpty)

        h.warmup.engineLikely(.defaultEngine)
        #expect(h.engine.preloads == 1)
        #expect(!h.input.isMonitoring)
    }

    @Test("An unavailable engine is never touched")
    func unavailableEngine() {
        let h = Harness()
        h.engine.availability = .unavailable(.notBundled)
        h.warmup.engineLikely(.restoredPage)
        #expect(h.engine.preloads == 0)
        #expect(!h.input.isMonitoring)
        #expect(h.warmup.phase == .idle)
    }

    @Test("A running engine needs no warmup, and one started by a page meanwhile ends the wait")
    func alreadyRunning() async {
        let running = Harness()
        running.engine.isRunning = true
        running.warmup.engineLikely(.restoredPage)
        #expect(running.engine.preloads == 0)
        #expect(running.warmup.phase == .started)

        let h = Harness()
        h.warmup.engineLikely(.restoredPage)
        h.engine.isRunning = true
        h.clock += 1
        h.idle.fireNow()
        await h.settle()
        #expect(h.engine.starts.isEmpty)
        #expect(h.warmup.phase == .started)
        #expect(!h.input.isMonitoring)
    }

    @Test("Only the first likely reason takes effect")
    func oncePerProcess() async {
        let h = Harness()
        h.warmup.engineLikely(.palette)
        h.warmup.engineLikely(.restoredPage)
        #expect(h.warmup.reason == .palette)
        #expect(h.engine.preloads == 1)
        h.clock += 1
        h.idle.fireNow()
        await h.settle()
        h.warmup.engineLikely(.browserPage)
        #expect(h.engine.starts == [.palette])
    }

    @Test("Stop ends the wait without starting the engine")
    func stopEndsWait() async {
        let h = Harness()
        h.warmup.engineLikely(.palette)
        h.warmup.stop()
        #expect(h.warmup.phase == .abandoned)
        #expect(!h.input.isMonitoring)
        #expect(!h.idle.isScheduled)
        #expect(!h.giveUp.isScheduled)
    }

    @Test("The clock timer fires once, a reschedule replaces the pending deadline, and cancel drops it")
    func clockTimer() async {
        let timer = BrowserEngineWarmupClockTimer()
        var fired: [Int] = []
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            timer.schedule(after: .seconds(60)) { fired.append(1) }
            timer.schedule(after: .milliseconds(1)) {
                fired.append(2)
                done.resume()
            }
            #expect(timer.isScheduled)
        }
        #expect(fired == [2])
        #expect(!timer.isScheduled)

        // A cancelled 1 ms deadline would fire before a later 20 ms one.
        let cancelled = BrowserEngineWarmupClockTimer()
        cancelled.schedule(after: .milliseconds(1)) { fired.append(3) }
        cancelled.cancel()
        #expect(!cancelled.isScheduled)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            timer.schedule(after: .milliseconds(20)) {
                fired.append(4)
                done.resume()
            }
        }
        #expect(fired == [2, 4])
    }
}
