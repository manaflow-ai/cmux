@testable import CmuxNextApp
#if DEBUG || CMUX_BLOCKING_CHECKS
@testable import CmuxNextCompat
#endif
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

    /// A fake job: `statuses` answers each status read in turn (the last one repeats).
    @MainActor final class FakeJob {
        var statuses: [SMAppService.Status]
        var registerError: (any Error)?
        var calls: [String] = []

        init(_ statuses: [SMAppService.Status], registerError: (any Error)? = nil) {
            self.statuses = statuses
            self.registerError = registerError
        }

        var registration: ServerServiceRegistration {
            ServerServiceRegistration(
                status: {
                    self.calls.append("status")
                    return self.statuses.count > 1 ? self.statuses.removeFirst() : self.statuses[0]
                },
                register: {
                    self.calls.append("register")
                    if let error = self.registerError { throw error }
                },
                unregister: { self.calls.append("unregister") },
                openLoginItems: { self.calls.append("openLoginItems") })
        }
    }

    func enable(_ job: FakeJob) async -> Refusal? {
        do throws(Refusal) {
            try await job.registration.enable(requiresApproval: Refusal.requiresApproval, failed: Refusal.failed)
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
        #expect(job.calls == ["status", "register"])
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
