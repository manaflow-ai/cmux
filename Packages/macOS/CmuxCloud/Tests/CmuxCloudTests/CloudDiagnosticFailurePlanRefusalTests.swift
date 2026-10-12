@testable import CmuxCloud
import Foundation
import Testing

/// A `402` names what stopped the request in its `error` code. A full shared
/// pool on a paid team is not a missing plan, and must not read as one.
@Suite("Cloud diagnostic failure for plan refusals")
struct CloudDiagnosticFailurePlanRefusalTests {
    static let poolExceededBody = """
        {"error":"vm_resource_pool_exceeded","message":"Your VMs already use 20 of 20 vCPUs. This VM needs 4 vCPUs.",
         "resource":"vcpus","pool":{"vcpus":20,"memoryMb":40960},"used":{"vcpus":20,"memoryMb":40960},
         "requested":{"vcpus":4,"memoryMb":8192},"upgradePlanId":"max"}
        """

    @Test("A full shared pool is classified as capacity, not as the plan")
    func poolExceededIsNotPlan() {
        let error = VMClientError.httpStatus(402, Self.poolExceededBody)
        let failure = CloudDiagnosticFailure.classify(error)
        #expect(failure != .plan)
        #expect(failure.label != CloudDiagnosticFailure.plan.label)
    }
}
