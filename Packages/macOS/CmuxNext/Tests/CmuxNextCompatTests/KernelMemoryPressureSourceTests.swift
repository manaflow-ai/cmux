import CmuxNextCompat
import Dispatch
import Testing

/// A ``KernelMemoryPressureSource`` is safe to release in every state: never started, cancelled
/// before it started, and started then cancelled. libdispatch traps ("Release of an inactive
/// object") when the last reference to a dispatch source that was never activated goes, so a source
/// made eagerly in the init and activated only by ``KernelMemoryPressureSource/start(delivering:)``
/// crashes the process here.
///
/// The level comes from `kern.memorystatus_vm_pressure_level`, never the event's data, as in Chrome's
/// `system_memory_pressure_evaluator_mac.cc`: the source subscribes, then reads the level at start,
/// reads it again on each event and delivers only a change. The tests inject the kernel's level and
/// fire the handler that ``KernelMemoryPressureSource/start(delivering:)`` installs with the event
/// data libdispatch would hand it, so a handler that maps the data fails them.
@MainActor @Suite struct KernelMemoryPressureSourceTests {
    /// The raw `kern.memorystatus_vm_pressure_level` a test sets, and how often the source read it.
    nonisolated final class KernelLevel: Sendable {
        private nonisolated struct State {
            var raw: Int32?
            var reads = 0
        }

        // The source reads on whichever thread runs start and its handler; a test sets on main.
        private let state: Mutex<State>

        init(_ raw: Int32?) {
            state = Mutex(State(raw: raw))
        }

        func set(_ raw: Int32?) {
            state.withLock { $0.raw = raw }
        }

        var reads: Int {
            state.withLock { $0.reads }
        }

        func read() -> Int32? {
            state.withLock { state in
                state.reads += 1
                return state.raw
            }
        }
    }

    /// The kernel's events: holds the handler the source subscribes and fires it as the dispatch
    /// source would, with the event's coalesced data.
    nonisolated final class KernelEvents: Sendable {
        private nonisolated struct State {
            var handler: (@MainActor @Sendable (UInt) -> Void)?
            var subscriptions = 0
            var isCancelled = false
        }

        private nonisolated final class Subscription: MemoryPressureSubscription {
            let events: KernelEvents

            init(_ events: KernelEvents) {
                self.events = events
            }

            func cancel() {
                events.state.withLock { $0.isCancelled = true }
            }
        }

        // The source subscribes and cancels on whichever thread runs start and cancel.
        private let state = Mutex(State())

        var subscriptions: Int {
            state.withLock { $0.subscriptions }
        }

        var isCancelled: Bool {
            state.withLock { $0.isCancelled }
        }

        func subscribe(_ handler: @escaping @MainActor @Sendable (UInt) -> Void) -> any MemoryPressureSubscription {
            state.withLock { state in
                state.handler = handler
                state.subscriptions += 1
            }
            return Subscription(self)
        }

        /// Runs the installed handler with `event` as its data, also after a cancel (an event the
        /// main queue was already running when the source was cancelled).
        @MainActor func fire(_ event: DispatchSource.MemoryPressureEvent) {
            let handler = state.withLock { $0.handler }
            handler?(event.rawValue)
        }
    }

    /// Levels a subscriber got (main actor).
    final class Levels {
        var seen: [MemoryPressureLevel] = []
    }

    private func makeSource(_ kernel: KernelLevel, _ events: KernelEvents) -> KernelMemoryPressureSource {
        KernelMemoryPressureSource(readKernelLevel: { kernel.read() }, subscribe: { events.subscribe($0) })
    }

    @Test func releasingAnUnstartedSourceIsSafe() {
        var source: KernelMemoryPressureSource? = KernelMemoryPressureSource()
        #expect(source != nil)
        source = nil
        #expect(source == nil)
    }

    @Test func releasingASourceCancelledBeforeStartIsSafe() {
        var source: KernelMemoryPressureSource? = KernelMemoryPressureSource()
        source?.cancel()
        source = nil
        #expect(source == nil)
    }

    @Test func releasingAStartedThenCancelledSourceIsSafe() {
        var source: KernelMemoryPressureSource? = KernelMemoryPressureSource()
        source?.start { _ in }
        source?.cancel()
        source = nil
        #expect(source == nil)
    }

    @Test func theKernelLevelAtStartIsTheCurrentLevelBeforeAnyEvent() {
        let kernel = KernelLevel(4)
        let source = makeSource(kernel, KernelEvents())
        #expect(source.currentLevel == .normal)
        let events = MemoryPressureEvents(source: source)
        let levels = Levels()
        let registration = events.observe { levels.seen.append($0) }
        #expect(events.currentLevel == .critical, "the level at start was not read")
        #expect(source.currentLevel == .critical)
        #expect(levels.seen.isEmpty, "the level read at start was delivered")
        withExtendedLifetime((events, registration)) {}
    }

    @Test func aCoalescedWarnThenNormalEventGivesTheKernelsNormal() {
        let kernel = KernelLevel(4)
        let kernelEvents = KernelEvents()
        let events = MemoryPressureEvents(source: makeSource(kernel, kernelEvents))
        let levels = Levels()
        let registration = events.observe { levels.seen.append($0) }
        // From critical the kernel went to warn, then normal; libdispatch coalesced both into one
        // event whose data is WARN|NORMAL (reads as warning). The kernel's level is 1: normal.
        kernel.set(1)
        kernelEvents.fire([.warning, .normal])
        #expect(levels.seen == [.normal])
        #expect(events.currentLevel == .normal)
        withExtendedLifetime((events, registration)) {}
    }

    @Test func anUnchangedLevelIsNotDeliveredAgain() {
        let kernel = KernelLevel(1)
        let kernelEvents = KernelEvents()
        let events = MemoryPressureEvents(source: makeSource(kernel, kernelEvents))
        let levels = Levels()
        let registration = events.observe { levels.seen.append($0) }
        kernelEvents.fire(.normal)
        kernel.set(2)
        kernelEvents.fire(.warning)
        kernelEvents.fire(.warning)
        kernel.set(4)
        kernelEvents.fire(.critical)
        kernelEvents.fire(.critical)
        #expect(levels.seen == [.warning, .critical])
        withExtendedLifetime((events, registration)) {}
    }

    @Test func aSubscriberReadsTheLevelItIsHanded() {
        let kernel = KernelLevel(1)
        let kernelEvents = KernelEvents()
        let events = MemoryPressureEvents(source: makeSource(kernel, kernelEvents))
        let levels = Levels()
        let registration = events.observe { _ in levels.seen.append(events.currentLevel) }
        kernel.set(2)
        kernelEvents.fire(.warning)
        #expect(levels.seen == [.warning])
        withExtendedLifetime((events, registration)) {}
    }

    @Test func anUnreadableOrUnknownLevelKeepsTheLastOne() {
        let kernel = KernelLevel(2)
        let kernelEvents = KernelEvents()
        let events = MemoryPressureEvents(source: makeSource(kernel, kernelEvents))
        let levels = Levels()
        let registration = events.observe { levels.seen.append($0) }
        kernel.set(nil)
        kernelEvents.fire(.normal)
        kernel.set(3)
        kernelEvents.fire(.normal)
        #expect(levels.seen.isEmpty)
        #expect(events.currentLevel == .warning)
        withExtendedLifetime((events, registration)) {}
    }

    /// The source subscribes before it reads the level at start: a change between the read and the
    /// subscription would otherwise give no event, and the stale level would last until the next one.
    /// Here the kernel goes to warning while start reads normal; the event the change gives wins.
    @Test func aChangeDuringTheStartReadIsNotLost() {
        let kernel = KernelLevel(1)
        let kernelEvents = KernelEvents()
        let source = KernelMemoryPressureSource(
            readKernelLevel: {
                let raw = kernel.read()
                if kernel.reads == 1 {
                    // Start's read saw normal; the kernel changes before start stores it.
                    kernel.set(2)
                    MainActor.assumeIsolated { kernelEvents.fire(.warning) }
                }
                return raw
            },
            subscribe: { kernelEvents.subscribe($0) }
        )
        let levels = Levels()
        source.start { levels.seen.append($0) }
        #expect(levels.seen == [.warning], "the change during start gave no event")
        #expect(source.currentLevel == .warning, "the stale read at start overwrote the event's level")
        source.cancel()
    }

    @Test func aCancelledSourceDeliversNothing() {
        let kernel = KernelLevel(1)
        let kernelEvents = KernelEvents()
        let source = makeSource(kernel, kernelEvents)
        let levels = Levels()
        source.start { levels.seen.append($0) }
        source.cancel()
        #expect(kernelEvents.isCancelled, "cancel did not cancel the subscription")
        kernel.set(4)
        kernelEvents.fire(.critical)
        #expect(levels.seen.isEmpty)
        #expect(source.currentLevel == .normal)
    }

    /// Event-driven: the source subscribes once and reads the kernel once at start and once per
    /// event, never on a timer.
    @Test func theSourceReadsTheKernelOnlyAtStartAndOnEvents() {
        let kernel = KernelLevel(1)
        let kernelEvents = KernelEvents()
        let source = makeSource(kernel, kernelEvents)
        #expect(kernel.reads == 0)
        #expect(kernelEvents.subscriptions == 0)
        source.start { _ in }
        #expect(kernel.reads == 1)
        #expect(kernelEvents.subscriptions == 1)
        source.start { _ in }
        #expect(kernel.reads == 1, "a second start read the kernel")
        #expect(kernelEvents.subscriptions == 1, "a second start subscribed again")
        kernelEvents.fire(.normal)
        #expect(kernel.reads == 2)
        source.cancel()
    }
}
