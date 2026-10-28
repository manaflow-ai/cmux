import CmuxNextCompat
import CoreFoundation
import CoreGraphics
import Foundation
import QuartzCore

extension VSyncHub {
    struct Entry: Sendable {
        let id: UInt64
        let owner: String
        let callback: @Sendable (Tick) -> Demand
        var armed: Bool
        /// Moves on every arm, so a tick that started before an arm cannot disarm it.
        var generation: UInt64 = 0
        /// The rate it asked for (``Subscription/requestFrameRate(_:)``); nil: the display's full rate.
        var rate: LinkRate?
    }

    /// A link's frame rate range, as a `Sendable` value (`CAFrameRateRange` crosses to the hub thread).
    struct LinkRate: Sendable, Equatable {
        let minimum: Float
        let maximum: Float
        let preferred: Float

        init(_ range: CAFrameRateRange) {
            minimum = range.minimum
            maximum = range.maximum
            preferred = range.preferred ?? range.maximum
        }

        var range: CAFrameRateRange { CAFrameRateRange(minimum: minimum, maximum: maximum, preferred: preferred) }

        /// Every display frame (``FrameRate/motion``): what a subscriber gets unless it asks for less.
        static let full = LinkRate(FrameRate.motion.range)

        /// Faster than `other` (Chrome's `FrameRateDecider` takes the shortest interval of the sinks
        /// that draw, components/viz/service/display/frame_rate_decider.cc).
        func isFaster(than other: LinkRate) -> Bool {
            (preferred, maximum, minimum) > (other.preferred, other.maximum, other.minimum)
        }
    }

    struct Armed: Sendable {
        let id: UInt64
        let generation: UInt64
        let callback: @Sendable (Tick) -> Demand
    }

    /// A display's subscribers, how many are armed and the rate the armed ones need. Each change
    /// returns whether the link must change now (run or pause, or a new rate).
    struct Entries {
        private(set) var list: [Entry] = []
        private(set) var armedCount = 0
        /// The fastest rate an armed subscriber asked for (``LinkRate/full`` while none is armed).
        private(set) var rate = LinkRate.full

        /// Returns true when the link must change: the entry is the first armed one, or asks for more.
        mutating func add(_ entry: Entry) -> Bool {
            list.append(entry)
            guard entry.armed else { return false }
            armedCount += 1
            return settle(armedChanged: armedCount == 1)
        }

        /// Returns true when the link must change: no subscriber is armed after it, or the rate drops.
        mutating func remove(_ id: UInt64) -> Bool {
            guard let index = list.firstIndex(where: { $0.id == id }) else { return false }
            guard list.remove(at: index).armed else { return false }
            armedCount -= 1
            return settle(armedChanged: armedCount == 0)
        }

        /// Returns true when the link must change: the entry is now the only armed one, or asks for more.
        mutating func arm(_ id: UInt64) -> Bool {
            guard let index = list.firstIndex(where: { $0.id == id }) else { return false }
            list[index].generation &+= 1
            guard !list[index].armed else { return false }
            list[index].armed = true
            armedCount += 1
            return settle(armedChanged: armedCount == 1)
        }

        /// Returns true when the link must change: no subscriber is armed after it, or the rate drops.
        mutating func disarm(_ id: UInt64) -> Bool {
            guard let index = list.firstIndex(where: { $0.id == id }), list[index].armed else { return false }
            list[index].armed = false
            armedCount -= 1
            return settle(armedChanged: armedCount == 0)
        }

        /// Returns true when the link must change to the entry's new rate.
        mutating func request(_ id: UInt64, rate: LinkRate) -> Bool {
            guard let index = list.firstIndex(where: { $0.id == id }), list[index].rate != rate else { return false }
            list[index].rate = rate
            return list[index].armed && settle(armedChanged: false)
        }

        /// Disarms the subscribers whose tick returned ``Demand/done`` and that were not armed again
        /// since.
        mutating func disarm(finished: [Armed]) {
            var changed = false
            for done in finished {
                guard let index = list.firstIndex(where: { $0.id == done.id }),
                      list[index].armed, list[index].generation == done.generation else { continue }
                list[index].armed = false
                armedCount -= 1
                changed = true
            }
            if changed { _ = settle(armedChanged: false) }
        }

        func armedSubscribers() -> [Armed] {
            list.filter(\.armed).map { Armed(id: $0.id, generation: $0.generation, callback: $0.callback) }
        }

        /// Recomputes ``rate`` after the armed set changed; true when the link must change.
        private mutating func settle(armedChanged: Bool) -> Bool {
            var fastest: LinkRate?
            for entry in list where entry.armed {
                let wanted = entry.rate ?? .full
                if fastest.map({ wanted.isFaster(than: $0) }) ?? true { fastest = wanted }
            }
            let next = fastest ?? .full
            defer { rate = next }
            return armedChanged || next != rate
        }
    }

    /// One display: its hub thread, its link and its subscribers. Subscribers change from any thread
    /// under `entries`; the link is used only on the hub thread (blocks posted to it, and the link's
    /// own ticks there), so its lock is never contended. The thread starts with the display's first
    /// link, so a display that never gets one (no screen) costs no thread.
    final class Display: Sendable {
        let id: CGDirectDisplayID
        private let thread: HubThread
        private let entries = Mutex(Entries())
        /// Vsyncs since creation; the newest is the tick's sequence.
        private let vsyncs = Atomic<UInt64>(0)
        private let link = Mutex<Installed?>(nil)

        /// The link and the rate it was last asked for (hub thread only).
        private struct Installed {
            let link: any VSyncLink
            var rate: LinkRate?
        }

        init(id: CGDirectDisplayID, threadName: String) {
            self.id = id
            thread = HubThread(name: threadName)
        }

        var armedCount: Int { entries.withLock { $0.armedCount } }

        var vsyncCount: UInt64 { vsyncs.load(ordering: .relaxed) }

        /// The hub thread runs (it started with the first link and was not stopped).
        var hasThread: Bool { thread.isRunning }

        // MARK: Any thread

        /// Hands `made` to the hub thread, which replaces the old link with it and attaches it to its run
        /// loop (paused while nobody is armed). Starts the thread with the first link; returns true then.
        @discardableResult
        func install(_ made: any VSyncLink) -> Bool {
            thread.post { [self] in
                let old = link.withLock { link in
                    defer { link = Installed(link: made) }
                    return link
                }
                old?.link.invalidate()
                apply()
                made.attachToCurrentRunLoop()
            }
            return thread.start()
        }

        /// Drops the link on the hub thread; the thread stays for the next one.
        func dropLinkLater() {
            thread.post { [self] in dropLink() }
        }

        func add(_ entry: Entry) {
            guard entries.withLock({ $0.add(entry) }) else { return }
            thread.post { [self] in apply() }
        }

        /// Removes a subscriber; the link goes with the display's last one.
        func remove(_ id: UInt64, lastSubscriber: Bool) {
            let changed = entries.withLock { $0.remove(id) }
            if lastSubscriber {
                dropLinkLater()
            } else if changed {
                thread.post { [self] in apply() }
            }
        }

        func arm(_ id: UInt64) {
            guard entries.withLock({ $0.arm(id) }) else { return }
            thread.post { [self] in apply() }
        }

        func disarm(_ id: UInt64) {
            guard entries.withLock({ $0.disarm(id) }) else { return }
            thread.post { [self] in apply() }
        }

        func request(_ id: UInt64, rate: LinkRate) {
            guard entries.withLock({ $0.request(id, rate: rate) }) else { return }
            thread.post { [self] in apply() }
        }

        /// Runs `work` on the hub thread on a later pass of its run loop.
        func post(_ work: @escaping @Sendable () -> Void) {
            thread.post(work)
        }

        /// Drops the link and ends the thread.
        func stop() {
            dropLinkLater()
            thread.stop()
        }

        // MARK: Hub thread

        private func dropLink() {
            let old = link.withLock { link in
                defer { link = nil }
                return link
            }
            old?.link.invalidate()
        }

        /// Runs the link while a subscriber is armed, at the fastest rate an armed one asked for, and
        /// pauses it otherwise.
        private func apply() {
            let (paused, rate) = entries.withLock { ($0.armedCount == 0, $0.rate) }
            guard let installed = link.withLock({ $0 }) else { return }
            if !paused, installed.rate != rate {
                installed.link.requestFrameRate(rate.range)
                link.withLock { installed in
                    guard installed != nil else { return }
                    installed?.rate = rate
                }
            }
            if installed.link.isPaused != paused { installed.link.isPaused = paused }
        }

        func vsync(timestamp: CFTimeInterval, targetTimestamp: CFTimeInterval) { // perf-hot: 0.5ms frame-tick (every vsync of an armed display)
            let sequence = vsyncs.add(1, ordering: .relaxed).newValue
            let tick = Tick(display: id, timestamp: timestamp, targetTimestamp: targetTimestamp, sequence: sequence)
            let armed = entries.withLock { $0.armedSubscribers() }
            let finished = armed.filter { $0.callback(tick) == .done }
            // Nothing armed (an arm raced the pause) or a tick finished: pause or slow the link. An arm
            // racing this posts an apply, which runs after this tick and unpauses.
            guard armed.isEmpty || !finished.isEmpty else { return }
            entries.withLock { $0.disarm(finished: finished) }
            apply()
        }
    }

    /// A display's thread: its own run loop at user-interactive QoS, running the link's ticks and
    /// the blocks other threads post to it, in posting order. It starts on the first ``start()``;
    /// blocks posted before its run loop exists run first, in order.
    final class HubThread: Sendable {
        private struct State {
            /// The thread's run loop; other threads only perform blocks on it and wake it (both thread-safe).
            var runLoop: CFRunLoop?
            /// Posted before the thread's run loop existed; the thread runs them first.
            var early: [@Sendable () -> Void] = []
            var started = false
            /// Set by ``stop()``: the thread leaves its run loop, or never enters it when the stop
            /// came first (`CFRunLoopStop` on a run loop that is not running does nothing).
            var stopped = false
        }

        private let name: String
        private let state = Mutex(State())
        private let onExit: (@Sendable () -> Void)?

        /// - Parameter onExit: Runs on the thread as it ends (tests).
        init(name: String, onExit: (@Sendable () -> Void)? = nil) {
            self.name = name
            self.onExit = onExit
        }

        /// The thread started and was not stopped.
        var isRunning: Bool { state.withLock { $0.started && !$0.stopped } }

        /// Starts the thread unless it started or stopped before; returns true when it starts now.
        func start() -> Bool {
            let starts = state.withLock { state in
                guard !state.started, !state.stopped else { return false }
                state.started = true
                return true
            }
            guard starts else { return false }
            // qos-allow: a frame waits on it (userInteractive; threading-model.md, the VSyncHub row)
            let thread = Thread { [self] in run() }
            thread.name = name
            thread.qualityOfService = .userInteractive
            thread.start()
            return true
        }

        /// Runs `work` on this thread on a later pass of its run loop.
        func post(_ work: @escaping @Sendable () -> Void) {
            state.withLock { state in
                guard let runLoop = state.runLoop else { return state.early.append(work) }
                // main-hop-allow: the display's own link thread's run loop, not main
                CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, work)
                CFRunLoopWakeUp(runLoop)
            }
        }

        /// Ends the run loop after the blocks posted before this call.
        func stop() {
            state.withLock { $0.stopped = true }
            post { CFRunLoopStop(CFRunLoopGetCurrent()) }
        }

        private func run() {
            // A source nobody signals keeps the run loop alive, asleep, while no link is attached.
            var context = CFRunLoopSourceContext()
            context.perform = { _ in }
            let keepAlive = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), keepAlive, .commonModes)
            let early = state.withLock { state in
                state.runLoop = CFRunLoopGetCurrent()
                defer { state.early = [] }
                return state.early
            }
            for work in early { work() }
            // A stop sets the flag before it posts CFRunLoopStop, so a stop that came before the run
            // loop ran ends it here, and one that comes later stops the run below.
            while !state.withLock({ $0.stopped }) {
                CFRunLoopRun()
            }
            CFRunLoopSourceInvalidate(keepAlive)
            state.withLock { $0.runLoop = nil }
            onExit?()
        }
    }
}
