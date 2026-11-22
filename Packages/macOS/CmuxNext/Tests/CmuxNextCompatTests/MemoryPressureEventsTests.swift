import CmuxNextCompat
import Testing

/// ``MemoryPressureEvents`` hands each level its source reports to every subscriber on the main actor,
/// calls a subscriber no more once its registration is cancelled or released, and cancels its source
/// when it goes. The source is a ``ManualMemoryPressureSource``, so the test delivers each event.
@MainActor @Suite struct MemoryPressureEventsTests {
    /// Levels a subscriber got (main actor).
    final class Levels {
        var seen: [MemoryPressureLevel] = []
    }

    @Test func eachSubscriberGetsEachLevelTheSourceReports() {
        let source = ManualMemoryPressureSource()
        let events = MemoryPressureEvents(source: source)
        let first = Levels()
        let second = Levels()
        let registrations = [events.observe { first.seen.append($0) }, events.observe { second.seen.append($0) }]
        source.send(.warning)
        source.send(.critical)
        #expect(first.seen == [.warning, .critical])
        #expect(second.seen == [.warning, .critical])
        withExtendedLifetime((events, registrations)) {}
    }

    /// The kernel sends its pressure event to some processes only (the largest first), and never one for the
    /// level a process starts under: on Nov 4 the app read `normal` for minutes while the kernel was at warning
    /// and critical. ``MemoryPressureEvents/refresh()`` reads the level now and hands it to every subscriber.
    @Test func refreshHandsTheLevelReadNowToEverySubscriber() {
        let source = ManualMemoryPressureSource()
        let events = MemoryPressureEvents(source: source)
        let levels = Levels()
        let registration = events.observe { levels.seen.append($0) }
        source.level = .critical // the kernel's level; no event came
        events.refresh()
        #expect(levels.seen == [.critical])
        source.level = nil // a source that cannot read the level hands nothing
        events.refresh()
        #expect(levels.seen == [.critical])
        withExtendedLifetime((events, registration)) {}
    }

    /// The kernel's source reads the level from its injected reader (the sysctl in the app).
    @Test func theKernelSourceReadsTheLevelNow() {
        #expect(KernelMemoryPressureSource(read: { .warning }).currentLevel() == .warning)
        #expect(KernelMemoryPressureLevel.level(kernel: 4) == .critical)
    }

    @Test func aCancelledSubscriberGetsNoLaterEvent() {
        let source = ManualMemoryPressureSource()
        let events = MemoryPressureEvents(source: source)
        let levels = Levels()
        let registration = events.observe { levels.seen.append($0) }
        source.send(.warning)
        registration.cancel()
        source.send(.critical)
        #expect(levels.seen == [.warning], "a cancelled subscriber still got an event")
        withExtendedLifetime((events, registration)) {}
    }

    @Test func aReleasedSubscriberGetsNoLaterEvent() {
        let source = ManualMemoryPressureSource()
        let events = MemoryPressureEvents(source: source)
        let levels = Levels()
        var registration: MainActorHandlerRegistration<MemoryPressureLevel>? = events.observe { levels.seen.append($0) }
        source.send(.warning)
        registration = nil
        source.send(.critical)
        #expect(registration == nil)
        #expect(levels.seen == [.warning], "a released subscriber still got an event")
        withExtendedLifetime(events) {}
    }

    @Test func releasingTheEventsCancelsTheirSource() {
        let source = ManualMemoryPressureSource()
        var events: MemoryPressureEvents? = MemoryPressureEvents(source: source)
        #expect(events != nil)
        #expect(!source.isCancelled)
        events = nil
        #expect(source.isCancelled, "the events went but their source still runs")
    }
}
