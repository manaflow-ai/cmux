@testable import CmuxCloud
import CmuxCloudResizeCore
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

extension CloudDiagnosticFailurePlanRefusalTests {
    private static func body(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    @Test("A full vCPU pool names what is free and the request, with Max as the secondary way through")
    func poolExceededMessageNamesTheVcpuShortfall() throws {
        let refusal = try #require(CloudPlanRefusal(VMClientError.httpStatus(402, Self.poolExceededBody)))
        #expect(refusal.code == "vm_resource_pool_exceeded")
        #expect(refusal.kind == .resourcePool(.vcpus(requested: 4, free: 0, pool: 20)))
        #expect(refusal.offersUpgrade)
        #expect(refusal.message == CloudVMResourcePool.shortfallText(.vcpus(requested: 4, free: 0, pool: 20), offersUpgrade: true))
        #expect(CloudDiagnosticFailure.message(for: VMClientError.httpStatus(402, Self.poolExceededBody)) == refusal.message)
    }

    @Test("A full memory pool on Max names the memory and offers no upgrade")
    func poolExceededMemoryOnMax() throws {
        let body = Self.body([
            "error": "vm_resource_pool_exceeded", "resource": "memoryMb",
            "pool": ["vcpus": 80, "memoryMb": 163_840], "used": ["vcpus": 40, "memoryMb": 147_456],
            "requested": ["vcpus": 8, "memoryMb": 32_768], "upgradePlanId": NSNull(),
        ])
        let refusal = try #require(CloudPlanRefusal(status: 402, body: body))
        #expect(refusal.kind == .resourcePool(.memory(requestedMb: 32_768, freeMb: 16_384, poolMb: 163_840)))
        #expect(!refusal.offersUpgrade)
        #expect(refusal.diagnosticFailure == .capacity)
    }

    @Test("A pool refusal without numbers still reads as capacity")
    func poolExceededWithoutNumbers() throws {
        let refusal = try #require(CloudPlanRefusal(status: 402, body: #"{"error":"vm_resource_pool_exceeded"}"#))
        #expect(refusal.kind == .resourcePool(nil))
        #expect(refusal.message == CloudDiagnosticFailure.capacity.label)
    }

    @Test("Each recognised 402 code maps to its own class and sentence")
    func recognisedCodes() throws {
        let active = try #require(CloudPlanRefusal(status: 402, body: #"{"error":"vm_active_limit_exceeded","limit":5}"#))
        #expect(active.kind == .activeLimit)
        #expect(active.diagnosticFailure == .capacity)
        let credits = try #require(CloudPlanRefusal(status: 402, body: #"{"error":"vm_create_credits_insufficient","amount":1}"#))
        #expect(credits.kind == .createCredits)
        #expect(credits.diagnosticFailure == .plan)
        #expect(credits.message != CloudDiagnosticFailure.plan.label)
        let memory = try #require(CloudPlanRefusal(status: 402, body: #"{"error":"vm_memory_requires_plan","upgradePlanId":"max"}"#))
        #expect(memory.kind == .memoryRequiresPlan)
        #expect(memory.diagnosticFailure == .plan)
        #expect(memory.message != CloudDiagnosticFailure.plan.label)
    }

    @Test("A zero active limit is the subscribe gate and keeps the server's sentence")
    func zeroActiveLimitIsTheSubscribeGate() throws {
        let refusal = try #require(CloudPlanRefusal(status: 402, body: Self.body([
            "error": "vm_active_limit_exceeded", "limit": 0,
            "message": "Cloud VMs require a cmux Pro subscription.",
        ])))
        #expect(refusal.kind == .other)
        #expect(refusal.message == "Cloud VMs require a cmux Pro subscription.")
    }

    @Test("An unrecognised 402 prefers the server's sentence, else the plan sentence")
    func unrecognisedCodes() throws {
        let explained = try #require(CloudPlanRefusal(status: 402, body: Self.body([
            "error": "vm_hours_limit_reached", "message": "fallback", "ui": ["message": "You used this month's hours."],
        ])))
        #expect(explained.message == "You used this month's hours.")
        let bare = try #require(CloudPlanRefusal(status: 402, body: #"{"error":"vm_new_gate"}"#))
        #expect(bare.message == CloudDiagnosticFailure.plan.label)
    }

    @Test("A 402 without a code keeps the status classification")
    func statusOnlyFallback() {
        #expect(CloudPlanRefusal(status: 402, body: "not json") == nil)
        #expect(CloudPlanRefusal(status: 402, body: #"{"message":"no code"}"#) == nil)
        #expect(CloudPlanRefusal(status: 409, body: #"{"error":"vm_resource_pool_exceeded"}"#) == nil)
        #expect(CloudDiagnosticFailure.classify(VMClientError.httpStatus(402, "")) == .plan)
        #expect(CloudDiagnosticFailure.message(for: VMClientError.httpStatus(402, "")) == CloudDiagnosticFailure.plan.label)
        #expect(CloudDiagnosticFailure.classify(MachineUsageClientError.httpStatus(402, Self.poolExceededBody)) == .capacity)
        #expect(CloudDiagnosticFailure.classify(VMClientError.httpStatus(503, Self.poolExceededBody)) == .server)
    }
}
