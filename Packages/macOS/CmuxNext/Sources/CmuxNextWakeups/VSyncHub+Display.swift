import CmuxNextCompat
import CoreFoundation
import CoreGraphics
import Foundation

extension VSyncHub {
    struct Entry: Sendable {
        let id: UInt64
        let owner: String
        let callback: @Sendable (Tick) -> Demand
        var armed: Bool
        /// Moves on every arm, so a tick that started before an arm cannot disarm it.
        var generation: UInt64 = 0
    }

    struct Armed: Sendable {
        let id: UInt64
        let generation: UInt64
        let callback: @Sendable (Tick) -> Demand
    }

    /// A display's subscribers and how many are armed. Each change returns whether the link must
    /// run or pause now.
    struct Entries {
        private(set) var list: [Entry] = []
        private(set) var armedCount = 0

        /// Returns true when the entry is the display's first armed subscriber.
        mutating func add(_ entry: Entry) -> Bool {
            list.append(entry)
            guard entry.armed else { return false }
            armedCount += 1
            return armedCount == 1
        }

        /// Returns true when the removal left no subscriber armed.
        mutating func remove(_ id: UInt64) -> Bool {
            guard let index = list.firstIndex(where: { $0.id == id }) else { return false }
            guard list.remove(at: index).armed else { return false }
            armedCount -= 1
            return armedCount == 0
        }

        /// Returns true when the entry is now the only armed subscriber.
        mutating func arm(_ id: UInt64) -> Bool {
            guard let index = list.firstIndex(where: { $0.id == id }) else { return false }
            list[index].generation &+= 1
            guard !list[index].armed else { return false }
            list[index].armed = true
            armedCount += 1
            return armedCount == 1
        }

        /// Returns true when no subscriber is armed after it.
        mutating func disarm(_ id: UInt64) -> Bool {
            guard let index = list.firstIndex(where: { $0.id == id }), list[index].armed else { return false }
            list[index].armed = false
            armedCount -= 1
            return armedCount == 0
        }

        /// Disarms the subscribers whose tick returned ``Demand/done`` and that were not armed again
        /// since; returns true when none is armed after it.
        mutating func disarm(finished: [Armed]) -> Bool {
            for done in finished {
                guard let index = list.firstIndex(where: { $0.id == done.id }),
                      list[index].armed, list[index].generation == done.generation else { continue }
                list[index].armed = false
                armedCount -= 1
            }
            return armedCount == 0
        }

        func armedSubscribers() -> [Armed] {
            list.filter(\.armed).map { Armed(id: $0.id, generation: $0.generation, callback: $0.callback) }
        }
    }

    /// One display: its hub thread, its link and its subscribers. Subscribers change from any thread
    /// under `entries`; the link is used only on the hub thread (blocks posted to it, and the link's
    /// own ticks there), so its lock is never contended.
    final class Display: Sendable {
        let id: CGDirectDisplayID
        private let thread: HubThread
        private let entries = Mutex(Entries())
        /// Vsyncs since creation; the newest is the tick's sequence.
        private let vsyncs = Atomic<UInt64>(0)
        private let link = Mutex<(any VSyncLink)?>(nil)

        init(id: CGDirectDisplayID, threadName: String) {
            self.id = id
            thread = HubThread.started(name: threadName)
        }

        var armedCount: Int { entries.withLock { $0.armedCount } }

        var vsyncCount: UInt64 { vsyncs.load(ordering: .relaxed) }

        // MARK: Any thread

        /// Hands `made` to the hub thread, which attaches it to its run loop (paused while nobody is armed).
        func install(_ made: any VSyncLink) {
            thread.post { [self] in
                let old = link.withLock { link in
                    defer { link = made }
                    return link
                }
                old?.invalidate()
                made.isPaused = armedCount == 0
                made.attachToCurrentRunLoop()
            }
        }

        func add(_ entry: Entry) {
            guard entries.withLock({ $0.add(entry) }) else { return }
            thread.post { [self] in reconcile() }
        }

        /// Removes a subscriber; the link goes with the display's last one.
        func remove(_ id: UInt64, lastSubscriber: Bool) {
            let nowIdle = entries.withLock { $0.remove(id) }
            if lastSubscriber {
                thread.post { [self] in dropLink() }
            } else if nowIdle {
                thread.post { [self] in reconcile() }
            }
        }

        func arm(_ id: UInt64) {
            guard entries.withLock({ $0.arm(id) }) else { return }
            thread.post { [self] in reconcile() }
        }

        func disarm(_ id: UInt64) {
            guard entries.withLock({ $0.disarm(id) }) else { return }
            thread.post { [self] in reconcile() }
        }

        /// Runs `work` on the hub thread on a later pass of its run loop.
        func post(_ work: @escaping @Sendable () -> Void) {
            thread.post(work)
        }

        /// Drops the link and ends the thread.
        func stop() {
            thread.post { [self] in dropLink() }
            thread.stop()
        }

        // MARK: Hub thread

        private func dropLink() {
            let old = link.withLock { link in
                defer { link = nil }
                return link
            }
            old?.invalidate()
        }

        /// Runs the link while a subscriber is armed and pauses it otherwise.
        private func reconcile() {
            let paused = armedCount == 0
            guard let current = link.withLock({ $0 }) else { return }
            if current.isPaused != paused { current.isPaused = paused }
        }

        func vsync(timestamp: CFTimeInterval, targetTimestamp: CFTimeInterval) { // perf-hot: 0.5ms frame-tick (every vsync of an armed display)
            let sequence = vsyncs.add(1, ordering: .relaxed).newValue
            let tick = Tick(display: id, timestamp: timestamp, targetTimestamp: targetTimestamp, sequence: sequence)
            let armed = entries.withLock { $0.armedSubscribers() }
            let finished = armed.filter { $0.callback(tick) == .done }
            let idle = armed.isEmpty || entries.withLock { $0.disarm(finished: finished) }
            // An arm racing this posts a reconcile, which runs after this tick and unpauses.
            if idle, let current = link.withLock({ $0 }) { current.isPaused = true }
        }
    }

    /// A display's thread: its own run loop at user-interactive QoS, running the link's ticks and
    /// the blocks other threads post to it, in posting order.
    final class HubThread: Sendable {
        private struct State {
            /// The thread's run loop; other threads only perform blocks on it and wake it (both thread-safe).
            var runLoop: CFRunLoop?
            /// Posted before the thread's run loop existed; the thread runs them first.
            var early: [@Sendable () -> Void] = []
        }

        private let state = Mutex(State())

        private init() {}

        static func started(name: String) -> HubThread {
            let hub = HubThread()
            // qos-allow: a frame waits on it (userInteractive; threading-model.md, the VSyncHub row)
            let thread = Thread { hub.run() }
            thread.name = name
            thread.qualityOfService = .userInteractive
            thread.start()
            return hub
        }

        /// Runs `work` on this thread on a later pass of its run loop.
        func post(_ work: @escaping @Sendable () -> Void) {
            state.withLock { state in
                guard let runLoop = state.runLoop else { return state.early.append(work) }
                CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, work)
                CFRunLoopWakeUp(runLoop)
            }
        }

        /// Ends the run loop after the blocks posted before this call.
        func stop() {
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
            CFRunLoopRun()
            CFRunLoopSourceInvalidate(keepAlive)
        }
    }
}
