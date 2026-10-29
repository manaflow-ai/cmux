@testable import CmuxNextActions
import Testing

/// Records each perform turn it hears, and what the handler saw of the turns so far.
@MainActor
private final class TurnRecorder: ActionRunObserver {
    var turns: [ActionTurn] = []

    func performTurnEnded(_ turn: ActionTurn) {
        turns.append(turn)
    }
}

/// The perform-turn observer (`ActionRunObserver`): the registry reports the end of
/// each outermost perform turn once, after the handler ran, with the canonical id, the origin and
/// whether it ran; a perform nested in a handler is part of its outer turn; a registry with no
/// observer behaves as before. Run: `swift test --filter ActionTurnObserverTests`.
@MainActor
@Suite struct ActionTurnObserverTests {
    private static func registry(_ observer: TurnRecorder?) -> ActionRegistry {
        ActionRegistry(catalog: [], aliases: ["test.old": "test.run"], runTiming: NoActionRunTiming(), turnObserver: observer)
    }

    @Test func aTurnIsReportedOnceAfterTheHandlerRan() {
        let observer = TurnRecorder()
        let registry = Self.registry(observer)
        var seenByHandler: [Int] = []
        registry.register(Action(id: "test.run", title: "Run") { seenByHandler.append(observer.turns.count) })

        #expect(registry.perform("test.run", invocation: ActionInvocation(origin: .cli)))
        #expect(seenByHandler == [0])
        #expect(observer.turns == [ActionTurn(id: "test.run", origin: .cli, ran: true)])
    }

    @Test func aRefusedRunIsATurnThatDidNotRun() {
        let observer = TurnRecorder()
        let registry = Self.registry(observer)
        registry.register(Action(id: "test.off", title: "Off", isEnabled: { false }) {})

        #expect(!registry.perform("test.off"))
        #expect(!registry.perform("test.unbound"))
        #expect(observer.turns == [ActionTurn(id: "test.off", origin: .user, ran: false),
                                   ActionTurn(id: "test.unbound", origin: .user, ran: false)])
    }

    @Test func anAliasIsReportedUnderItsCanonicalID() {
        let observer = TurnRecorder()
        let registry = Self.registry(observer)
        registry.register(Action(id: "test.run", title: "Run") {})

        #expect(registry.perform("test.old"))
        #expect(observer.turns.map(\.id) == ["test.run"])
    }

    @Test func aNestedPerformIsPartOfItsOuterTurn() {
        let observer = TurnRecorder()
        let registry = Self.registry(observer)
        var innerRan = false
        registry.register(Action(id: "test.inner", title: "Inner") { innerRan = true })
        registry.register(Action(id: "test.outer", title: "Outer") { [weak registry] in _ = registry?.perform("test.inner") })

        #expect(registry.perform("test.outer"))
        #expect(innerRan)
        #expect(observer.turns == [ActionTurn(id: "test.outer", origin: .user, ran: true)])

        // The depth is back at zero: the next outermost perform is its own turn.
        #expect(registry.perform("test.inner"))
        #expect(observer.turns.map(\.id) == ["test.outer", "test.inner"])
    }

    @Test func aRegistryWithNoObserverRunsAsBefore() {
        let registry = Self.registry(nil)
        var runs = 0
        registry.register(Action(id: "test.run", title: "Run") { runs += 1 })

        #expect(registry.turnObserver == nil)
        #expect(registry.perform("test.run"))
        #expect(runs == 1)
        #expect(registry.observedPerformDepth == 0)
    }
}
