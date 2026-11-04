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
}
