@testable import CmuxCloud
import Foundation
import Testing

@Suite("Cloud hub startup recovery plan")
struct CloudWireGuardHubRecoveryPlanTests {
    private let busy = VMClientError.httpStatus(
        409,
        #"{"error":"vm_access_grant_busy","retryable":true,"retryAfterSeconds":5}"#
    )
    private let hubFailure = CloudWireGuardHub.HubError.notReady("stale WireGuard enrollment")

    @Test("The first attempt uses the written enrollment")
    func firstAttemptIsOrdinary() {
        #expect(!CloudWireGuardHubRecoveryPlan().refreshesNextEnrollment)
    }

    @Test("A busy answer waits as long as the server asked")
    func busyHonorsRetryAfter() {
        var plan = CloudWireGuardHubRecoveryPlan()
        #expect(plan.recordFailure(busy, backoff: .seconds(1)) == .seconds(5))
        #expect(plan.recordFailure(busy, backoff: .seconds(8)) == .seconds(8))
        #expect(plan.recordFailure(hubFailure, backoff: .seconds(2)) == .seconds(2))
    }

    @Test("A rejected ordinary enrollment is not turned into a forced replacement")
    func rejectedEnrollmentStaysOrdinary() {
        var plan = CloudWireGuardHubRecoveryPlan()
        _ = plan.recordFailure(busy, backoff: .seconds(1))
        #expect(!plan.refreshesNextEnrollment)
        _ = plan.recordFailure(busy, backoff: .seconds(1))
        #expect(!plan.refreshesNextEnrollment)
    }

    @Test("A failed hub replaces its enrollment once, then reuses the replacement")
    func hubFailureReplacesOnce() {
        var plan = CloudWireGuardHubRecoveryPlan()
        _ = plan.recordFailure(hubFailure, backoff: .seconds(1))
        #expect(plan.refreshesNextEnrollment)
        // The replacement enrolled, then the hub failed again: a second
        // replacement would only contend for this Mac's access lease.
        _ = plan.recordFailure(hubFailure, backoff: .seconds(2))
        #expect(!plan.refreshesNextEnrollment)
        _ = plan.recordFailure(hubFailure, backoff: .seconds(4))
        #expect(!plan.refreshesNextEnrollment)
    }

    @Test("A rejected replacement is asked for again")
    func rejectedReplacementRetries() {
        var plan = CloudWireGuardHubRecoveryPlan()
        _ = plan.recordFailure(hubFailure, backoff: .seconds(1))
        #expect(plan.refreshesNextEnrollment)
        #expect(plan.recordFailure(busy, backoff: .seconds(2)) == .seconds(5))
        #expect(plan.refreshesNextEnrollment)
    }

    @Test("Server waits are read only from retryable statuses and are bounded")
    func serverRetryAfter() {
        #expect(busy.serverRetryAfter == .seconds(5))
        #expect(VMClientError.httpStatus(503, #"{"retryAfterSeconds":30}"#).serverRetryAfter == .seconds(30))
        #expect(VMClientError.httpStatus(429, #"{"retryAfterSeconds":9999}"#).serverRetryAfter == .seconds(60))
        #expect(VMClientError.httpStatus(403, #"{"retryAfterSeconds":5}"#).serverRetryAfter == nil)
        #expect(VMClientError.httpStatus(409, #"{"retryAfterSeconds":0}"#).serverRetryAfter == nil)
        #expect(VMClientError.httpStatus(409, "not json").serverRetryAfter == nil)
        #expect(VMClientError.notSignedIn.serverRetryAfter == nil)
    }
}
