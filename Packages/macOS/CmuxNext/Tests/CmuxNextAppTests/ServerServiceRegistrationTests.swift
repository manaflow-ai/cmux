@testable import CmuxNextApp
#if DEBUG || CMUX_BLOCKING_CHECKS
@testable import CmuxNextCompat
#endif
import CmuxNextServerHelper
import CmuxNextWakeups
import Foundation
import ServiceManagement
import Testing

/// "Make This Mac a Server" and the helper's registration (plans/cmux-next/chrome-parity/p02-threads.md, task 140):
/// the `SMAppService` status and register calls wait for backgroundtaskmanagementd, so they run on the system
/// lane, and the toggle driven from the main actor records no blocking site there. The fake service drives
/// each registration state; the real one names an agent plist the test runner does not carry, so launchd
/// changes nothing on the host.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct ServerServiceRegistrationTests {
    enum Refusal: Error, Equatable {
        case requiresApproval
        case failed(String)
    }

    struct Boom: Error, CustomStringConvertible {
        var description: String { "boom" }
    }

    /// A fake job: `statuses` answers each status read in turn (the last one repeats); a `statusError` read throws.
    @MainActor final class FakeJob {
        var statuses: [SMAppService.Status]
        var registerError: (any Error)?
        var statusError: (any Error)?
        var calls: [String] = []

        init(_ statuses: [SMAppService.Status], registerError: (any Error)? = nil, statusError: (any Error)? = nil) {
            self.statuses = statuses
            self.registerError = registerError
            self.statusError = statusError
        }

        func readStatus() throws -> SMAppService.Status {
            calls.append("status")
            if let statusError { throw statusError }
            return statuses.count > 1 ? statuses.removeFirst() : statuses[0]
        }

        func register() throws {
            calls.append("register")
            if let registerError { throw registerError }
        }

        var registration: ServerServiceRegistration {
            ServerServiceRegistration(
                status: { try self.readStatus() },
                ensureRegistered: {
                    try ServerServiceRegistration.ensureRegistered(status: { try self.readStatus() },
                                                                   register: { try self.register() })
                },
                unregister: { self.calls.append("unregister") },
                openLoginItems: { self.calls.append("openLoginItems") })
        }
    }

    /// A launchd that registers a job once: a second register finds it registered and throws, as
    /// `kSMErrorAlreadyRegistered` does. `staleReads` reads answer "not registered" whatever the state: the
    /// reads of enables that overlapped and read before either registered.
    @MainActor final class FakeLaunchd {
        var state: SMAppService.Status = .notRegistered
        var staleReads: Int
        var registers = 0

        init(staleReads: Int) { self.staleReads = staleReads }

        func read() -> SMAppService.Status {
            guard staleReads == 0 else {
                staleReads -= 1
                return .notRegistered
            }
            return state
        }

        func register() throws {
            guard state == .notRegistered else { throw AlreadyRegistered() }
            state = .enabled
            registers += 1
        }

        var registration: ServerServiceRegistration {
            ServerServiceRegistration(
                status: { self.read() },
                ensureRegistered: {
                    try ServerServiceRegistration.ensureRegistered(status: { self.read() }, register: { try self.register() })
                },
                unregister: {},
                openLoginItems: {})
        }
    }

    struct AlreadyRegistered: Error {}

    @MainActor final class Reverted {
        var fixes: [ServerFix] = []
    }

    func enable(_ job: FakeJob) async -> Refusal? {
        await enable(job.registration)
    }

    func enable(_ registration: ServerServiceRegistration) async -> Refusal? {
        do throws(Refusal) {
            try await registration.enable(requiresApproval: Refusal.requiresApproval, failed: Refusal.failed)
            return nil
        } catch {
            return error
        }
    }

    @Test func anEnabledJobStaysEnabledWithNoRegister() async {
        let job = FakeJob([.enabled])
        #expect(await enable(job) == nil)
        #expect(job.calls == ["status"])
    }

    @Test func aJobAwaitingApprovalOpensLoginItemsWithoutRegistering() async {
        let job = FakeJob([.requiresApproval])
        #expect(await enable(job) == .requiresApproval)
        #expect(job.calls == ["status", "openLoginItems"])
    }

    @Test func anUnregisteredJobRegistersAndReportsApprovalWhenLaunchdAsksForIt() async {
        let approval = FakeJob([.notRegistered, .requiresApproval])
        #expect(await enable(approval) == .requiresApproval)
        #expect(approval.calls == ["status", "register", "status", "openLoginItems"])

        let enabled = FakeJob([.notRegistered, .enabled])
        #expect(await enable(enabled) == nil)
        #expect(enabled.calls == ["status", "register", "status"])
    }

    @Test func aFailedRegisterKeepsLaunchdsReasonAndOpensNothing() async {
        let job = FakeJob([.notFound], registerError: Boom())
        #expect(await enable(job) == .failed("boom"))
        #expect(job.calls == ["status", "register", "status"])
    }

    /// Two enables of one job overlap on the system lane (a double trigger from the menu and the palette, or a
    /// script that runs the action twice): both read "not registered" before either registers (the stale
    /// reads), the second register finds the job registered, and both succeed with one registration.
    @Test func overlappingEnablesRegisterOnceAndBothSucceed() async {
        let launchd = FakeLaunchd(staleReads: 2)
        let first = launchd.registration, second = launchd.registration
        #expect(await enable(first) == nil)
        #expect(await enable(second) == nil)
        #expect(launchd.registers == 1)
        #expect(launchd.state == .enabled)
    }

    @Test func aStatusThatWasNotReadIsAFailureNotARegistrationState() async {
        let job = FakeJob([.notRegistered], statusError: CancellationError())
        #expect(await enable(job) == .failed(String(describing: CancellationError())))
        #expect(job.calls == ["status"])
    }

    /// Stop Serving with an enabled helper whose status read fails (app quit drops the lane item, or the task
    /// is cancelled) and an empty ledger: it neither skips the reverts as if no helper were registered nor
    /// unregisters the helper; it fails, so the person can stop serving again and get the settings back.
    @Test func stopServingKeepsTheHelperWhenItsStatusWasNotRead() async {
        let helper = FakeJob([.enabled], statusError: CancellationError())
        let agent = FakeJob([.enabled])
        let reverted = Reverted()
        let ledger = ServerFixLedger(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("server-fix-ledger-\(UUID().uuidString)/ledger.json"))
        let stop = ServerStopServing(agent: agent.registration, helper: helper.registration,
                                     revert: { (fix: ServerFix) async throws(ServerHelperClient.Failure) in reverted.fixes.append(fix) },
                                     gate: ServerFixGate(), ledger: ledger)
        var failure: ServerStopServing.Failure?
        do throws(ServerStopServing.Failure) {
            try await stop.run()
        } catch {
            failure = error
        }
        #expect(failure == .revert(String(describing: CancellationError())))
        #expect(reverted.fixes.isEmpty)
        #expect(helper.calls == ["status"], "the helper was unregistered with its state unknown")
        #expect(agent.calls == ["status", "unregister"])

        let unknownAgent = FakeJob([.enabled], statusError: CancellationError())
        let agentOnly = ServerStopServing(agent: unknownAgent.registration, helper: nil,
                                          revert: { (_: ServerFix) async throws(ServerHelperClient.Failure) in },
                                          gate: ServerFixGate(), ledger: ledger)
        await #expect(throws: ServerStopServing.Failure.unregister(String(describing: CancellationError()))) { try await agentOnly.run() }
        #expect(unknownAgent.calls == ["status"])
    }

    @Test func theAgentRefusesBeforeAnyLaunchdCallWhenItCannotRegister() async {
        let job = FakeJob([.notRegistered])
        for (bundled, allowed, refusal) in [(false, true, ServerLaunchAgent.Failure.notInBuild), (true, false, ServerLaunchAgent.Failure.notReady)] {
            let agent = ServerLaunchAgent(isBundled: { bundled }, allowRegister: { allowed }, service: job.registration)
            await #expect(throws: refusal) { try await agent.register() }
        }
        #expect(job.calls.isEmpty)
    }

    @Test func theAgentMapsTheRegistrationsRefusals() async {
        let agent = ServerLaunchAgent(isBundled: { true }, allowRegister: { true },
                                      service: FakeJob([.notRegistered, .requiresApproval]).registration)
        await #expect(throws: ServerLaunchAgent.Failure.requiresApproval) { try await agent.register() }
        let failing = ServerLaunchAgent(isBundled: { true }, allowRegister: { true },
                                        service: FakeJob([.notRegistered], registerError: Boom()).registration)
        await #expect(throws: ServerLaunchAgent.Failure.failed("boom")) { try await failing.register() }
    }

    #if DEBUG || CMUX_BLOCKING_CHECKS
    /// The real registration, driven from the main actor as the toggle is: its status and register calls go to
    /// the system lane, so the main thread records no blocking site.
    @Test func theTogglesLaunchdCallsNeverBlockTheMainThread() async {
        let opened = FakeJob([.notFound])
        var service = ServerServiceRegistration.agent(work: BackgroundWork(label: "test.server-agent"))
        service.openLoginItems = opened.registration.openLoginItems
        let agent = ServerLaunchAgent(isBundled: { true }, allowRegister: { true }, service: service)
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let refusal: ServerLaunchAgent.Failure? = await BlockingViolationTable.$scoped.withValue(table) {
            do throws(ServerLaunchAgent.Failure) {
                try await agent.register()
                return nil
            } catch {
                return error
            }
        }
        await table.flush()
        #expect(BlockingDetector(table: table).sites.isEmpty, "a launchd call blocked the main thread")
        // No plist in the test runner: launchd refuses the register, and nothing opens System Settings.
        #expect(refusal != nil)
        #expect(opened.calls.isEmpty)
    }
    #endif
}
