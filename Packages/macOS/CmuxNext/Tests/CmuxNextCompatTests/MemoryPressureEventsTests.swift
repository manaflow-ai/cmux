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
