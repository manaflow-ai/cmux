import CmuxNextCloud
import CmuxNextDaemon
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

    /// The plan the Mac reads with `cloud.plan.get` (the machine list carries none): a Pro team
    /// pays for Cloud, the platform's `none` does not, and an answer without a plan is no answer.
    @Test func theAppServerPlanSaysWhetherThePlanPays() throws {
        func plan(_ text: String) throws -> CloudMachineLimits? {
            CloudMachineLimits(nextPlan: try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))
        }
        let pro = try #require(try plan(#"{"plan_id":"pro","upgrade_plan":"max","limits":{"max_active":3,"max_saved":10,"memory_options_mb":[4096],"locked_memory_options_mb":[]},"usage":{"active":1,"saved":0,"period_end":0}}"#))
        #expect(pro.paysForCloud)
        #expect(pro.planId == "pro" && pro.maxActiveVms == 3 && pro.activeVmCount == 1)
        #expect(try plan(#"{"plan_id":"none","limits":{"max_active":0},"usage":{"active":0}}"#)?.paysForCloud == false)
        #expect(try plan(#"{"plan_id":"none","limits":{"max_active":0},"usage":{"active":0}}"#)?.planId == "free")
        #expect(try plan(#"{"limits":{"max_active":3}}"#) == nil)
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
