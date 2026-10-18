import CmuxNextActions
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Observation
import Testing
@testable import CmuxNextApp

/// Lifecycle signals only trigger reads of the original receipt; they cannot start work.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AgentCLIUpdateObservationTests {
    typealias JSONValue = CmuxNextSettings.JSONValue

    @MainActor final class Harness {
        let owner = AgentCLIUpdateActionsTests.Owner()
        let ledger = AgentCLIUpdateRecoveryTests.Ledger()
        let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var reads = 0
        var fail = false
        var retireDuringRead = false

        func route() -> AgentCLIUpdateActions.Route {
            let route = owner.route()
            let observe = route.observe
            return .init(machine: route.machine, session: route.session, isCurrent: route.isCurrent,
                inventory: route.inventory, start: route.start, observe: { receipt in
                self.reads += 1
                self.owner.outcome = self.reads == 1 ? "pending" : "exited"
                if self.retireDuringRead { self.owner.current = false }
                if self.fail { throw DaemonError.notConnected }
                return try await observe(receipt)
            }, changes: { self.changes.stream })
        }

        func make() -> (AgentCLIUpdateActions, ActionRegistry) {
            let actions = AgentCLIUpdateActions(capture: { _ in self.route() }, persistence: ledger.port,
                captureRecovered: { machine, session in
                    guard machine == self.owner.machine, session == self.owner.session else { throw DaemonError.notConnected }
                    return self.route()
                })
            let registry = ActionRegistry.standard(); actions.bind(into: registry)
            return (actions, registry)
        }

        func finish(_ actions: AgentCLIUpdateActions, key: String = "original") async {
            changes.continuation.yield()
            changes.continuation.finish()
            await actions.intents[key]?.following?.value
        }
    }

    @Test func settingsObservesTheOriginalTerminalWithoutRefreshOrAnotherDispatch() async throws {
        let h = Harness(); let (actions, registry) = h.make()
        _ = try await actions.runSettings(id: "work-profile",
            context: .init(page: "cmux.settings", opid: "original", userGesture: true, gestureEvent: 1), registry: registry)
        await h.finish(actions)
        let job = try #require(actions.state.arrayValue?.first)
        #expect(job["state"] == "exited" && job["exit_code"] == 23)
        #expect(job["intent_key"] == "original" && job["terminal"] == "term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        #expect(h.owner.starts.count == 1 && h.reads == 2)
        #expect(actions.settled == ["original"])
        await actions.refresh()
        #expect(actions.state.arrayValue?.first?["exit_code"] == 23)
        #expect(h.owner.starts.count == 1 && h.reads == 2, "settled jobs do not keep reading or dispatching")
    }

    @Test func paletteAndRecoveredJobsUseTheSameAutomaticObservation() async throws {
        let h = Harness(); let (actions, registry) = h.make()
        let work = registry.capturingWork {
            registry.perform("agent.harness.updateAll", invocation: .init(arguments: ["id": "work-profile"], origin: .user))
        }
        for task in work { #expect(await task.value == nil) }
        let key = try #require(actions.intents.keys.first)
        await h.finish(actions, key: key)
        #expect(actions.state.arrayValue?.first?["exit_code"] == 23)
        #expect(h.owner.starts.count == 1)

        let restored = Harness()
        let input = try AgentCLIUpdateIntent(key: "original", rootKey: "original", machine: restored.owner.machine,
            session: restored.owner.session, cli: .codex, profiles: ["work-profile"])
        restored.ledger.rows[input.key] = try .init(intent: input, receipt: restored.owner.receipt(.codex))
        let (recovered, _) = restored.make()
        try await recovered.recover()
        await restored.finish(recovered)
        #expect(recovered.state.arrayValue?.first?["exit_code"] == 23)
        #expect(restored.owner.starts.isEmpty && restored.owner.reads == 0)
    }

    @Observable @MainActor final class Admission {
        var current = true
    }

    @Test(arguments: [false, true])
    func nativeInvalidationsRequireTheOriginalSourceAndSerial(acceptCurrent: Bool) async throws {
        let store = DaemonStore()
        let source = UUID()
        _ = store.apply(batch: [.init(sequence: DaemonEventEnvelope.sequence(serial: 4, index: 0),
            event: .connected(DaemonIdentity(generation: "owner"), generationChanged: true), sourceID: source)])
        let stamp = try #require(store.sideEvents.controlStamp)
        let admission = Admission()
        let changes = AgentCLIUpdateActions.terminalChanges(sideEvents: store.sideEvents, stamp: stamp,
            current: { admission.current })
        _ = store.apply(batch: [
            .init(sequence: DaemonEventEnvelope.sequence(serial: 4, index: 10), event: .terminalRegistryChanged(revision: 7), sourceID: UUID()),
            .init(sequence: DaemonEventEnvelope.sequence(serial: 3, index: 10), event: .terminalRegistryChanged(revision: 8), sourceID: source),
            .init(sequence: DaemonEventEnvelope.sequence(serial: 4, index: 11), event: .bell(surface: 1), sourceID: source),
        ])
        if acceptCurrent {
            _ = store.apply(batch: [.init(sequence: DaemonEventEnvelope.sequence(serial: 4, index: 12),
                event: .terminalRegistryChanged(revision: 9), sourceID: source)])
        }
        admission.current = false
        var count = 0
        for await _ in changes { count += 1 }
        #expect(count == (acceptCurrent ? 1 : 0))
    }

    @Test(arguments: ["before", "during", "failed-read"])
    func withdrawnRoutesAndFailedReadsNeverInventCompletion(mode: String) async throws {
        let h = Harness(); let (actions, registry) = h.make()
        _ = try await actions.runSettings(id: "work-profile",
            context: .init(page: "cmux.settings", opid: "original", userGesture: true, gestureEvent: 1), registry: registry)
        if mode == "before" { h.owner.current = false }
        if mode == "during" { h.retireDuringRead = true }
        if mode == "failed-read" { h.fail = true }
        await h.finish(actions)
        #expect(actions.settled.isEmpty)
        #expect(actions.state.arrayValue?.first?["exit_code"] == nil)
        #expect(h.owner.starts.count == 1)
    }
}
