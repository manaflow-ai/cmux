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

    /// p08-startup-098: the app's events hold their source until the first frame. Until `start()` the source
    /// is not started and the level reads normal; `start()` starts it once and hands a non-normal level read at
    /// the start to the subscribers made before it.
    @Test func aHeldSourceStartsOnceAtStartAndHandsOnItsFirstLevel() {
        let source = ManualMemoryPressureSource(levelAtStart: .warning)
        let events = MemoryPressureEvents(source: source, startsNow: false)
        let levels = Levels()
        let registration = events.observe { levels.seen.append($0) }
        #expect(source.starts == 0, "a held source started before start()")
        #expect(events.currentLevel == .normal)
        events.start()
        #expect(source.starts == 1)
        #expect(events.currentLevel == .warning)
        #expect(levels.seen == [.warning], "a subscriber made before the start missed the level read at the start")
        events.start()
        #expect(source.starts == 1, "a second start() started the source again")
        #expect(levels.seen == [.warning])
        source.send(.critical)
        #expect(levels.seen == [.warning, .critical])
        withExtendedLifetime((events, registration)) {}
    }

    @Test func aSourceStartedInTheInitIsNotStartedAgainAndHandsNothingOnAtStart() {
        let source = ManualMemoryPressureSource(levelAtStart: .warning)
        let events = MemoryPressureEvents(source: source)
        let levels = Levels()
        let registration = events.observe { levels.seen.append($0) }
        #expect(source.starts == 1)
        events.start()
        #expect(source.starts == 1)
        #expect(levels.seen.isEmpty, "start() after an init start delivered the start's level")
        withExtendedLifetime((events, registration)) {}
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
