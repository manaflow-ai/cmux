import CmuxNextAgentPane
import Foundation
@testable import CmuxNextApp
import Testing

/// Cloud's pre-chat approval preparation follows the same typed safe-to-restart signal as the
/// remote daemon start. Failures stay on the unkeyed start path so a busy or shared machine can
/// still show its normal restart notice.
@Suite(.serialized)
struct CloudApprovalsPrepareTests {
    private actor Counter {
        var value = 0

        func increment() { value += 1 }
        func read() -> Int { value }
    }

    @Test func anIdleMachineRunsTheKeyedStartOnce() async {
        let machine = "cloud-approvals-idle-\(UUID().uuidString)"
        let starts = Counter()
        let prepared = await CloudService.prepareRemoteApprovals(
            machine: machine,
            preparation: .daemonSaidSafe,
            idle: { true },
            restart: {
                await starts.increment()
                return nil
            })

        #expect(prepared)
        #expect(await starts.read() == 1)
    }

    @Test func aBusyMachineDoesNotRestart() async {
        let machine = "cloud-approvals-busy-\(UUID().uuidString)"
        let starts = Counter()
        let prepared = await CloudService.prepareRemoteApprovals(
            machine: machine,
            preparation: .checkStatus,
            idle: { false },
            restart: {
                await starts.increment()
                return nil
            })

        #expect(!prepared)
        #expect(await starts.read() == 0)
    }

    @Test func aKeyedStartFailureFallsBackWithoutThrowing() async {
        let machine = "cloud-approvals-failure-\(UUID().uuidString)"
        let starts = Counter()
        let prepared = await CloudService.prepareRemoteApprovals(
            machine: machine,
            preparation: .daemonSaidSafe,
            idle: { true },
            restart: {
                await starts.increment()
                return .notSingleOwner
            })

        #expect(!prepared)
        #expect(await starts.read() == 1)
    }

    /// A sign-out, account change or deleted machine disconnects this session. The next
    /// person to view the shared-team machine must not inherit the creator's signer.
    @MainActor
    @Test func disconnectRevokesTheCloudMachineApprovalSigner() throws {
        let session = CloudLinkEndedHeaderTests.session(status: .paused)
        defer { session.disconnect() }
        let key = try #require(AcpmuxSecretKey())
        let instance = "creator-daemon"
        AcpmuxRemotePersonKeys.shared.bind(machine: session.machineID, instance: instance, key: key)
        #expect(AcpmuxRemotePersonKeys.shared.key(machine: session.machineID, instance: instance) === key)

        session.disconnect() // the same session retirement used on Cloud account teardown
        #expect(AcpmuxRemotePersonKeys.shared.key(machine: session.machineID, instance: instance) == nil)
    }

    /// The backend can finish keyed-start and person_holds *after* the Cloud account switched.
    /// A second switch back to the same account must also reject that earlier in-flight work.
    @MainActor
    @Test func anOldAccountOrAnOldEpochCannotBindAnApprovalKey() throws {
        let machine = "cloud-approvals-scope-\(UUID().uuidString)"
        let instance = "creator-daemon"
        let key = try #require(AcpmuxSecretKey())
        defer { AcpmuxRemotePersonKeys.shared.drop(machine: machine) }
        let originalAccount: [String?] = ["creator", "shared-team"]
        var currentAccount = originalAccount
        var epoch = 1
        let epochAtStart = epoch
        var connected = true
        let stillCurrent = {
            currentAccount == originalAccount && epoch == epochAtStart && connected
        }

        currentAccount = ["teammate", "shared-team"]
        #expect(!CloudService.bindVerifiedApprovalKey(machine: machine, instance: instance, key: key,
                                                      stillCurrent: stillCurrent))
        #expect(AcpmuxRemotePersonKeys.shared.key(machine: machine, instance: instance) == nil)

        currentAccount = originalAccount
        epoch += 1 // the original person came back after the other account
        #expect(!CloudService.bindVerifiedApprovalKey(machine: machine, instance: instance, key: key,
                                                      stillCurrent: stillCurrent))
        #expect(AcpmuxRemotePersonKeys.shared.key(machine: machine, instance: instance) == nil)

        epoch = epochAtStart
        connected = false // the originating machine session was retired
        #expect(!CloudService.bindVerifiedApprovalKey(machine: machine, instance: instance, key: key,
                                                      stillCurrent: stillCurrent))
        connected = true
        #expect(CloudService.bindVerifiedApprovalKey(machine: machine, instance: instance, key: key,
                                                     stillCurrent: stillCurrent))
        #expect(AcpmuxRemotePersonKeys.shared.key(machine: machine, instance: instance) === key)
    }
}
