import CmuxNextCompat
import Testing

/// A ``KernelMemoryPressureSource`` is safe to release in every state: never started, cancelled
/// before it started, and started then cancelled. libdispatch traps ("Release of an inactive
/// object") when the last reference to a dispatch source that was never activated goes, so a source
/// made eagerly in the init and activated only by ``KernelMemoryPressureSource/start(delivering:)``
/// crashes the process here.
///
/// The level comes from `kern.memorystatus_vm_pressure_level`, never the event's data, as in Chrome's
/// `system_memory_pressure_evaluator_mac.cc`: the source reads it at start and on each event and
/// delivers only a change. The tests inject the kernel's level and call the event handler
/// (``KernelMemoryPressureSource/kernelLevelMayHaveChanged()``) as the dispatch source would; the
/// handler takes no event data, so a coalesced WARN|NORMAL event can only give the level the
/// kernel reports.
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

    /// Levels a subscriber got (main actor).
    final class Levels {
        var seen: [MemoryPressureLevel] = []
    }

    private func makeSource(_ kernel: KernelLevel) -> KernelMemoryPressureSource {
        KernelMemoryPressureSource(readKernelLevel: { kernel.read() })
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
        let source = makeSource(kernel)
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
        let kernel = KernelLevel(2)
        let source = makeSource(kernel)
        let events = MemoryPressureEvents(source: source)
        let levels = Levels()
        let registration = events.observe { levels.seen.append($0) }
        // The kernel went to critical and back to normal; libdispatch coalesced both into one event
        // whose data is WARN|CRITICAL|NORMAL. The handler reads the kernel's level: 1.
        kernel.set(4)
        kernel.set(1)
        source.kernelLevelMayHaveChanged()
        #expect(levels.seen == [.normal])
        #expect(events.currentLevel == .normal)
        withExtendedLifetime((events, registration)) {}
    }

    @Test func anUnchangedLevelIsNotDeliveredAgain() {
        let kernel = KernelLevel(1)
        let source = makeSource(kernel)
        let events = MemoryPressureEvents(source: source)
        let levels = Levels()
        let registration = events.observe { levels.seen.append($0) }
        source.kernelLevelMayHaveChanged()
        kernel.set(2)
        source.kernelLevelMayHaveChanged()
        source.kernelLevelMayHaveChanged()
        kernel.set(4)
        source.kernelLevelMayHaveChanged()
        source.kernelLevelMayHaveChanged()
        #expect(levels.seen == [.warning, .critical])
        withExtendedLifetime((events, registration)) {}
    }

    @Test func aSubscriberReadsTheLevelItIsHanded() {
        let kernel = KernelLevel(1)
        let source = makeSource(kernel)
        let events = MemoryPressureEvents(source: source)
        let levels = Levels()
        let registration = events.observe { _ in levels.seen.append(events.currentLevel) }
        kernel.set(2)
        source.kernelLevelMayHaveChanged()
        #expect(levels.seen == [.warning])
        withExtendedLifetime((events, registration)) {}
    }

    @Test func anUnreadableOrUnknownLevelKeepsTheLastOne() {
        let kernel = KernelLevel(2)
        let source = makeSource(kernel)
        let events = MemoryPressureEvents(source: source)
        let levels = Levels()
        let registration = events.observe { levels.seen.append($0) }
        kernel.set(nil)
        source.kernelLevelMayHaveChanged()
        kernel.set(3)
        source.kernelLevelMayHaveChanged()
        #expect(levels.seen.isEmpty)
        #expect(events.currentLevel == .warning)
        withExtendedLifetime((events, registration)) {}
    }

    @Test func aCancelledSourceDeliversNothing() {
        let kernel = KernelLevel(1)
        let source = makeSource(kernel)
        let levels = Levels()
        source.start { levels.seen.append($0) }
        source.cancel()
        kernel.set(4)
        source.kernelLevelMayHaveChanged()
        #expect(levels.seen.isEmpty)
        #expect(source.currentLevel == .normal)
    }

    /// Event-driven: the source reads the kernel once at start and once per event, never on a timer.
    @Test func theSourceReadsTheKernelOnlyAtStartAndOnEvents() {
        let kernel = KernelLevel(1)
        let source = makeSource(kernel)
        #expect(kernel.reads == 0)
        source.start { _ in }
        #expect(kernel.reads == 1)
        source.start { _ in }
        #expect(kernel.reads == 1, "a second start read the kernel")
        source.kernelLevelMayHaveChanged()
        #expect(kernel.reads == 2)
        source.cancel()
    }
}
