@testable import CmuxCloud
import Foundation
import Testing

@Suite("Cloud hub startup recovery plan")
struct CloudWireGuardHubRecoveryPlanTests {
    private let busy = VMClientError.httpStatus(
        409,
        #"{"error":"vm_access_grant_busy","retryable":true,"retryAfterSeconds":5}"#
    )
    private let unavailable = VMClientError.httpStatus(
        503,
        #"{"error":"vm_tunnel_enrollment_unavailable","retryable":true,"retryAfterSeconds":30}"#
    )
    private let hubFailure = CloudWireGuardHub.HubError.notReady("stale WireGuard enrollment")

    @Test("The first attempt uses the written enrollment")
    func firstAttemptIsOrdinary() {
        #expect(!CloudWireGuardHubRecoveryPlan().refreshesNextEnrollment)
    }

    @Test("A retryable answer waits as long as the server asked")
    func honorsRetryAfter() {
        var plan = CloudWireGuardHubRecoveryPlan()
        #expect(plan.recordFailure(unavailable, enrolled: false, backoff: .seconds(1)) == .seconds(30))
        #expect(plan.recordFailure(unavailable, enrolled: false, backoff: .seconds(60)) == .seconds(60))
        #expect(plan.recordFailure(hubFailure, enrolled: true, backoff: .seconds(2)) == .seconds(2))
    }

    @Test("A busy Mac lease waits without spending restart attempts, within a budget")
    func busyLeaseWaits() {
        var plan = CloudWireGuardHubRecoveryPlan()
        var waited: Duration = .zero
        while let wait = plan.busyWait(after: busy) {
            #expect(wait == .seconds(5))
            waited += wait
        }
        #expect(waited == CloudWireGuardHubRecoveryPlan.busyBudget)
        #expect(plan.busyWait(after: unavailable) == nil)
        var fresh = CloudWireGuardHubRecoveryPlan()
        #expect(fresh.busyWait(after: hubFailure) == nil)
    }

    @Test("Restart attempts are bounded by the backoff table; busy waits are not attempts")
    func restartsAreBoundedByBackoff() {
        var plan = CloudWireGuardHubRecoveryPlan(backoff: [.seconds(1), .seconds(2)])
        #expect(plan.wait(after: busy, enrolled: false) == .seconds(5))
        #expect(plan.wait(after: hubFailure, enrolled: true) == .seconds(1))
        #expect(plan.wait(after: busy, enrolled: false) == .seconds(5))
        #expect(plan.wait(after: hubFailure, enrolled: true) == .seconds(2))
        #expect(plan.wait(after: hubFailure, enrolled: true) == nil)
    }

    @Test("A spent busy budget gives up instead of falling into ordinary restarts")
    func spentBusyBudgetGivesUp() {
        let longBusy = VMClientError.httpStatus(
            409, #"{"error":"vm_access_grant_busy","retryable":true,"retryAfterSeconds":60}"#
        )
        var plan = CloudWireGuardHubRecoveryPlan(backoff: [.seconds(1), .seconds(2), .seconds(4)])
        #expect(plan.wait(after: longBusy, enrolled: false) == .seconds(60))
        // The next 60 s would pass the 90 s budget: stop, rather than spend
        // the three restarts waiting 60 s each.
        #expect(plan.wait(after: longBusy, enrolled: false) == nil)
        // A different failure still gets its restart attempts.
        #expect(plan.wait(after: hubFailure, enrolled: true) == .seconds(1))
    }

    @Test("A refused ordinary enrollment is not turned into a forced replacement")
    func refusedEnrollmentStaysOrdinary() {
        var plan = CloudWireGuardHubRecoveryPlan()
        _ = plan.busyWait(after: busy)
        #expect(!plan.refreshesNextEnrollment)
        _ = plan.recordFailure(unavailable, enrolled: false, backoff: .seconds(1))
        #expect(!plan.refreshesNextEnrollment)
    }

    @Test("A failed hub replaces its enrollment once, then reuses the replacement")
    func hubFailureReplacesOnce() {
        var plan = CloudWireGuardHubRecoveryPlan()
        _ = plan.recordFailure(hubFailure, enrolled: true, backoff: .seconds(1))
        #expect(plan.refreshesNextEnrollment)
        // The replacement enrolled, then the hub failed again: a second
        // replacement would only contend for this Mac's access lease.
        _ = plan.recordFailure(hubFailure, enrolled: true, backoff: .seconds(2))
        #expect(!plan.refreshesNextEnrollment)
        _ = plan.recordFailure(hubFailure, enrolled: true, backoff: .seconds(4))
        #expect(!plan.refreshesNextEnrollment)
    }

    @Test("A replacement whose enrollment step failed, for any reason, is asked for again")
    func failedReplacementRetries() {
        var plan = CloudWireGuardHubRecoveryPlan()
        _ = plan.recordFailure(hubFailure, enrolled: true, backoff: .seconds(1))
        #expect(plan.busyWait(after: busy) == .seconds(5))
        #expect(plan.refreshesNextEnrollment)
        // Not a client error (a key write or transport failure), but the
        // enrollment step never finished, so nothing was replaced.
        _ = plan.recordFailure(URLError(.cannotWriteToFile), enrolled: false, backoff: .seconds(2))
        #expect(plan.refreshesNextEnrollment)
    }

    @Test("Server waits are read only from retryable statuses and are bounded")
    func serverRetryAfter() {
        #expect(busy.serverRetryAfter == .seconds(5))
        #expect(busy.serverErrorCode == "vm_access_grant_busy")
        #expect(unavailable.serverRetryAfter == .seconds(30))
        #expect(VMClientError.httpStatus(429, #"{"retryAfterSeconds":9999}"#).serverRetryAfter == .seconds(60))
        #expect(VMClientError.httpStatus(403, #"{"retryAfterSeconds":5}"#).serverRetryAfter == nil)
        #expect(VMClientError.httpStatus(409, #"{"retryAfterSeconds":0}"#).serverRetryAfter == nil)
        #expect(VMClientError.httpStatus(409, "not json").serverRetryAfter == nil)
        // An absurd delay is bounded instead of trapping on conversion.
        #expect(VMClientError.httpStatus(503, #"{"retryAfterSeconds":1e100}"#).serverRetryAfter == .seconds(60))
        #expect(VMClientError.httpStatus(503, #"{"retryAfterSeconds":2.5}"#).serverRetryAfter == .seconds(3))
        #expect(VMClientError.notSignedIn.serverRetryAfter == nil)
        #expect(VMClientError.notSignedIn.serverErrorCode == nil)
    }
}
