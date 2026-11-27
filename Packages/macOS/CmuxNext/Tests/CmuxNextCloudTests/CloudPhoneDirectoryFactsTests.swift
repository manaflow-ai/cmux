import CmuxNextCloud
import Foundation
import Testing

/// The plan and run facts the Mac hands hostd for the phone's Computer card (`cloud_links`).
struct CloudPhoneDirectoryFactsTests {
    @Test func onlyANamedPaidPlanWithOpenMachinesPays() {
        #expect(CloudMachineLimits(maxActiveVms: 3, activeVmCount: 0, planId: "pro").paysForCloud)
        // No cap is not a closed plan.
        #expect(CloudMachineLimits(maxActiveVms: nil, activeVmCount: 0, planId: "team").paysForCloud)
        #expect(!CloudMachineLimits(maxActiveVms: 3, activeVmCount: 0, planId: "free").paysForCloud)
        #expect(!CloudMachineLimits(maxActiveVms: 3, activeVmCount: 0, planId: "FREE").paysForCloud)
        #expect(!CloudMachineLimits(maxActiveVms: 0, activeVmCount: 0, planId: "pro").paysForCloud)
        #expect(!CloudMachineLimits(maxActiveVms: 3, activeVmCount: 0, planId: nil).paysForCloud)
    }

    @Test func aMachineHasRunOnceItRanOrIsBetweenRuns() {
        for status: CloudMachine.Status in [.running, .pausing, .paused, .starting] {
            #expect(CloudMachine(id: "vm", status: status).hasRun)
        }
        for status: CloudMachine.Status in [.provisioning, .failed, .unknown, .destroyed, .deleting] {
            #expect(!CloudMachine(id: "vm", status: status).hasRun)
        }
        var failed = CloudMachine(id: "vm", status: .failed)
        failed.runningSince = Date(timeIntervalSince1970: 1)
        #expect(failed.hasRun)
    }

    @Test func goneMachinesAreNotListed() {
        #expect(CloudMachine(id: "vm", status: .destroyed).isGoneForPhones)
        #expect(CloudMachine(id: "vm", status: .deleting).isGoneForPhones)
        var killing = CloudMachine(id: "vm", status: .running)
        killing.pendingChange = .deleting
        #expect(killing.isGoneForPhones)
        #expect(!CloudMachine(id: "vm", status: .paused).isGoneForPhones)
    }
}
