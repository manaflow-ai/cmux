import CmuxNextActions
@testable import CmuxNextAgentUpdates
@testable import CmuxNextDaemon
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
            registry.perform("agent.harness.updateAll", invocation: .init(arguments: ["id": .string("work-profile")], origin: .user))
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

    /// A live follow whose kept tab the person closes settles instead of blocking the CLI.
    @Test(arguments: ["terminal.closed", "selector.not_found"])
    func aFollowedTerminalThatClosesSettles(code: String) async throws {
        let h = Harness(); let (actions, registry) = h.make()
        _ = try await actions.runSettings(id: "work-profile",
            context: .init(page: "cmux.settings", opid: "original", userGesture: true, gestureEvent: 1), registry: registry)
        h.owner.observeError = .command(cmd: "terminal.wait_exit", message: "gone", code: code,
            details: CmuxNextDaemon.JSONValue.object(["scope": .string("terminal")]))
        await h.finish(actions)
        #expect(actions.settled == ["original"])
        #expect(h.ledger.rows.isEmpty)
        #expect(actions.state.arrayValue?.first?["state"] == "exited")
        _ = try await actions.runSettings(id: "work-profile",
            context: .init(page: "cmux.settings", opid: "after-close", userGesture: true, gestureEvent: 2), registry: registry)
        #expect(h.owner.starts.map(\.1) == ["original", "after-close"])
    }

    /// Each captured route subscribes to its own connection's changes; a reconnect is a new stream.
    @MainActor final class Connections {
        let owner = AgentCLIUpdateActionsTests.Owner()
        let ledger = AgentCLIUpdateRecoveryTests.Ledger()
        var subscriptions: [AsyncStream<Void>.Continuation] = []

        func route() -> AgentCLIUpdateActions.Route {
            var route = owner.route()
            route.changes = {
                let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                self.subscriptions.append(continuation)
                return events
            }
            return route
        }

        func waitForObservations(_ count: Int) async {
            for _ in 0..<500 where owner.observations < count { await Task.yield() }
        }
    }

    /// A reconnect (new epoch) to the same owner retires the old route. The next read of the
    /// jobs re-captures the owner and restarts the follow on the new connection, whose events
    /// then deliver the outcome with no refresh. Reads with no reconnect never subscribe again.
    @Test func aReconnectRestartsTheFollowOnTheNewConnectionAndRepeatedReadsDoNotDuplicateIt() async throws {
        let c = Connections()
        let actions = AgentCLIUpdateActions(capture: { _ in c.route() }, persistence: c.ledger.port)
        let registry = ActionRegistry.standard(); actions.bind(into: registry)
        _ = try await actions.runSettings(id: "work-profile",
            context: .init(page: "cmux.settings", opid: "original", userGesture: true, gestureEvent: 1), registry: registry)
        await c.waitForObservations(1)
        #expect(c.subscriptions.count == 1 && c.owner.observations == 1)
        let firstFollow = try #require(actions.intents["original"]?.following)
        #expect(actions.state.arrayValue?.first?["state"] == "pending")

        for _ in 0..<5 { _ = actions.state }
        #expect(c.subscriptions.count == 1, "reads with no reconnect start no other follow")
        #expect(actions.intents["original"]?.following == firstFollow)
        #expect(c.owner.captures == 1)

        c.owner.epoch += 1
        #expect(actions.state.arrayValue?.first?["state"] == "pending")
        #expect(c.owner.captures == 2, "the read after a reconnect re-captures the owner")
        #expect(c.subscriptions.count == 2, "the follow restarts on the new connection")
        let secondFollow = try #require(actions.intents["original"]?.following)
        #expect(secondFollow != firstFollow && firstFollow.isCancelled)
        for _ in 0..<5 { _ = actions.state }
        #expect(c.subscriptions.count == 2 && c.owner.captures == 2, "the fresh route is reused, not re-captured")
        #expect(actions.intents["original"]?.following == secondFollow)

        await c.waitForObservations(2)
        c.owner.outcome = "exited"
        c.subscriptions[1].yield()
        c.subscriptions[1].finish()
        await secondFollow.value
        let job = try #require(actions.state.arrayValue?.first)
        #expect(job["state"] == "exited" && job["exit_code"] == 23)
        #expect(actions.settled == ["original"] && c.ledger.rows.isEmpty)
        #expect(c.owner.starts.count == 1 && c.subscriptions.count == 2)
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
