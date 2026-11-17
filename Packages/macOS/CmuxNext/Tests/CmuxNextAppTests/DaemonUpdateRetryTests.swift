@testable import CmuxNextActions
import CmuxNextCompat
@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
import Observation
import Testing

/// Leo, 2026-11-17: "remove bullshit ceremony + bullshit text + bullshit belt and suspenders". A person's run that
/// needs a capability this Mac's older service lacks restarts that service (the server-update restart) and runs once
/// more, instead of "cmux's background service is out of date. Quit and reopen cmux to update it."
/// (``DaemonUpdateRetry``). Only a failed restart shows a line; another machine's reason names that machine.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DaemonUpdateRetryTests {
    static let offWhileOutdated: ActionID = "cloudOpenDesktop"
    static let refusesWhileOutdated: ActionID = "openSettings"

    /// This Mac's service as the retry sees it.
    @Observable @MainActor final class Service {
        /// The running service serves the capability.
        var updated = false
        var restarts = 0
        var generation = 1
        /// This app can restart it (launched by the app, connected).
        var restartable = true
        /// The service a restart brings up serves the capability.
        var successorServes = true
        /// The running restart, answered by the test: true when a successor came up.
        var answer: CheckedContinuation<Bool, Never>?
    }
    @Observable @MainActor final class Seen { var ran: [ActionID] = []; var refused: [String] = [] }

    struct Setup {
        let registry: ActionRegistry
        let service: Service
        let seen: Seen
        /// Weak: the registry alone keeps the retry alive, as in the App.
        weak var retry: DaemonUpdateRetry?
    }

    static func setup() -> Setup {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        let service = Service(), seen = Seen()
        registry.refusalObserver = { reason, _ in seen.refused.append(reason) }
        registry.bind(offWhileOutdated, unavailable: { service.updated ? nil : RefusalStrings.daemonOutdated },
                      invoke: { _ in seen.ran.append(offWhileOutdated) })
        registry.bind(refusesWhileOutdated, unavailable: { nil }, invoke: { _ in
            guard service.updated else { return registry.refuse(RefusalStrings.daemonOutdated) }
            seen.ran.append(refusesWhileOutdated)
        })
        let retry = DaemonUpdateRetry(restart: {
            service.restarts += 1
            guard await withCheckedContinuation({ service.answer = $0 }) else { return nil }
            service.generation += 1
            service.updated = service.successorServes
            return "g\(service.generation)"
        }, restartable: { service.restartable ? "g\(service.generation)" : nil })
        retry.bind(into: registry)
        return Setup(registry: registry, service: service, seen: seen, retry: retry)
    }

    static func until(_ done: @escaping @MainActor @Sendable () -> Bool) async {
        for await met in ObservationStream(done) where met { return }
    }

    /// Answers the restart once it is waiting.
    static func answerRestart(_ service: Service, _ updated: Bool) async {
        await until { service.answer != nil }
        service.answer?.resume(returning: updated)
        service.answer = nil
    }

    @Test func anOutdatedServiceRestartsOnceAndTheRunsGoAfterIt() async {
        let s = Self.setup()
        #expect(s.registry.perform(Self.offWhileOutdated, invocation: ActionInvocation()))
        s.registry.perform(Self.refusesWhileOutdated, invocation: ActionInvocation())
        #expect(s.retry?.waitingCount == 2, "the registry did not keep the retry alive")
        #expect(s.seen.refused.isEmpty, "a run was refused instead of restarting: \(s.seen.refused)")
        await Self.answerRestart(s.service, true)
        let seen = s.seen
        await Self.until { seen.ran.count == 2 }
        #expect(seen.ran == [Self.offWhileOutdated, Self.refusesWhileOutdated])
        #expect(s.service.restarts == 1, "one restart for every run that waited")
        #expect(seen.refused.isEmpty)
    }

    @Test func aFailedRestartShowsOneLineAndRunsNothing() async {
        let s = Self.setup()
        s.registry.perform(Self.offWhileOutdated, invocation: ActionInvocation())
        s.registry.perform(Self.refusesWhileOutdated, invocation: ActionInvocation())
        await Self.answerRestart(s.service, false)
        let seen = s.seen
        await Self.until { !seen.refused.isEmpty }
        #expect(seen.refused == [RefusalStrings.daemonUpdateFailed])
        #expect(seen.ran.isEmpty)
        #expect(s.retry?.waitingCount == 0)
    }

    @Test func theCLIIsRefusedWithTheReasonAndRestartsNothing() {
        let s = Self.setup()
        for origin in [ActionOrigin.cli, .mcp, .script] {
            #expect(!s.registry.perform(Self.offWhileOutdated, invocation: ActionInvocation(origin: origin)))
            let refused = s.registry.capturingRefusal {
                s.registry.perform(Self.refusesWhileOutdated, invocation: ActionInvocation(origin: origin))
            }
            #expect(refused == RefusalStrings.daemonOutdated)
        }
        #expect(s.service.restarts == 0)
    }

    /// A service this app cannot restart (not connected, or not launched by it) shows the reason; nothing waits.
    @Test func aServiceThisAppCannotRestartShowsTheReason() {
        let s = Self.setup()
        s.service.restartable = false
        s.registry.perform(Self.refusesWhileOutdated, invocation: ActionInvocation())
        #expect(s.seen.refused == [RefusalStrings.daemonOutdated])
        #expect(s.service.restarts == 0)
        #expect(s.retry?.waitingCount == 0)
    }

    /// A restart whose service still lacks the capability runs the action once (it shows its reason) and is never
    /// restarted again for it: no restart loop.
    @Test func aRestartedServiceThatStillLacksItIsNotRestartedAgain() async {
        let s = Self.setup()
        s.service.successorServes = false
        s.registry.perform(Self.refusesWhileOutdated, invocation: ActionInvocation())
        await Self.answerRestart(s.service, true)
        let seen = s.seen
        await Self.until { seen.refused.count == 1 }
        #expect(seen.refused == [RefusalStrings.daemonOutdated])
        s.registry.perform(Self.refusesWhileOutdated, invocation: ActionInvocation())
        #expect(seen.refused == [RefusalStrings.daemonOutdated, RefusalStrings.daemonOutdated])
        #expect(s.service.restarts == 1)
        #expect(seen.ran.isEmpty)
    }

    /// Another machine's older cmux is named and never restarts this Mac's service; this Mac's is the retried reason.
    @Test func anotherMachinesReasonNamesItAndIsNotRetried() {
        let remote = DaemonService(machineID: "ssh:build-box")
        remote.store.identity = DaemonIdentity(machineName: "build-box", generation: "g1")
        let reason = remote.missingCapabilityMessage(DaemonCapability.rows.rawValue)
        #expect(reason == RefusalStrings.updateMachine("build-box"))
        #expect(reason.contains("build-box"))
        #expect(!DaemonUpdateRetry.retries(reason))

        let local = DaemonService(machineID: "local")
        local.store.identity = DaemonIdentity(generation: "g1")
        let localReason = local.missingCapabilityMessage(DaemonCapability.rows.rawValue)
        #expect(localReason == RefusalStrings.daemonOutdated)
        #expect(DaemonUpdateRetry.retries(localReason))
        #expect(!localReason.contains("Quit and reopen"))
    }
}
