import Foundation
import Testing
@testable import CmuxCloudMachines

/// Production, 2026-09-29: one Mac sent `POST /api/vm/tunnel` 134 times in an
/// hour after its Cloud access grant was revoked. The server answered the same
/// permanent `403 vm_access_revoked` every time, and the Mac retried it in
/// bursts of four. These tests pin the gate that turns that answer into one
/// request per login.
struct CloudTunnelEnrollmentGateTests {
    /// The exact body `web/services/vms/routeHelpers.ts` sends.
    private static let revokedBody = Data(#"""
    {"phase":"network","retryable":false,"ui":{"title":"Cloud VM authentication required","message":"Cloud access for this Mac login was revoked.","phase":"network","severity":"error","retryable":false},"error":"vm_access_revoked","message":"Cloud access for this Mac login was revoked.","reason":"Cloud access for this Mac login was revoked.","action":"Sign out of cmux, then sign in again to enroll this Mac."}
    """#.utf8)

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("vm_access_revoked is classified as a revoked login")
    func revokedIsClassified() {
        let failure = CloudTunnelEnrollmentGate.classify(status: 403, body: Self.revokedBody)
        #expect(failure.kind == .accessRevoked)
        #expect(failure.kind.isPermanent)
    }

    @Test("A revoked login stays blocked with no expiry, and only for that login")
    func revokedHoldsForTheLogin() {
        var gate = CloudTunnelEnrollmentGate()
        gate.recordFailure("account|7", CloudTunnelEnrollmentGate.classify(status: 403, body: Self.revokedBody), now: now)
        let oneYearLater = now.addingTimeInterval(365 * 24 * 60 * 60)
        #expect(gate.blockedUntil("account|7", now: oneYearLater) != nil)
        #expect(gate.isAccessRevoked("account|7"))
        // Signing in again starts a new session generation: a new key.
        #expect(gate.blockedUntil("account|8", now: now) == nil)
        #expect(!gate.isAccessRevoked("account|8"))
    }

    @Test("An explicit retryable:false refusal is held, not retried in a burst")
    func explicitNonRetryableHolds() {
        let body = Data(#"{"error":"vm_tunnel_invalid_key","retryable":false,"ui":{"retryable":false}}"#.utf8)
        let failure = CloudTunnelEnrollmentGate.classify(status: 400, body: body)
        #expect(failure.kind == .notRetryable)
        var gate = CloudTunnelEnrollmentGate(notRetryableHold: 30 * 60)
        let until = gate.recordFailure("login", failure, now: now)
        #expect(until == now.addingTimeInterval(30 * 60))
        #expect(!gate.isAccessRevoked("login"))
    }

    @Test("Retryable refusals back off exponentially to the cap and honor retryAfterSeconds")
    func retryableBacksOff() {
        let busy = Data(#"{"error":"vm_access_grant_busy","retryable":true,"retryAfterSeconds":1}"#.utf8)
        #expect(CloudTunnelEnrollmentGate.classify(status: 409, body: busy) == .init(kind: .retryable, retryAfterSeconds: 1))
        let unavailable = Data(#"{"error":"vm_tunnel_enrollment_unavailable","retryable":true,"retryAfterSeconds":30}"#.utf8)
        let failure = CloudTunnelEnrollmentGate.classify(status: 503, body: unavailable)
        #expect(failure == .init(kind: .retryable, retryAfterSeconds: 30))

        var gate = CloudTunnelEnrollmentGate(baseDelay: 2, maxDelay: 60)
        #expect(gate.recordFailure("login", failure, now: now) == now.addingTimeInterval(30))
        let plain = CloudTunnelEnrollmentGate.Failure(kind: .retryable)
        #expect(gate.recordFailure("login", plain, now: now) == now.addingTimeInterval(4))
        #expect(gate.recordFailure("login", plain, now: now) == now.addingTimeInterval(8))
        for _ in 0..<10 { gate.recordFailure("login", plain, now: now) }
        #expect(gate.blockedUntil("login", now: now) == now.addingTimeInterval(60))
        #expect(gate.blockedUntil("login", now: now.addingTimeInterval(61)) == nil)
    }

    @Test("Transient and unreadable answers stay retryable")
    func transientStaysRetryable() {
        #expect(CloudTunnelEnrollmentGate.classify(status: 502, body: Data("<html>".utf8)).kind == .retryable)
        #expect(CloudTunnelEnrollmentGate.classify(status: 500, body: Data(#"{"error":"vm_internal","ui":{"retryable":false}}"#.utf8)).kind == .retryable)
        #expect(CloudTunnelEnrollmentGate.classify(status: 429, body: Data("{}".utf8)).kind == .retryable)
        // The auth layer owns 401 and refreshes the session; the gate must not
        // lock a login out on one stale token.
        #expect(CloudTunnelEnrollmentGate.classify(status: 401, body: Data("{}".utf8)).kind == .retryable)
    }

    @Test("A success clears the login's entry")
    func successClears() {
        var gate = CloudTunnelEnrollmentGate()
        gate.recordFailure("login", .init(kind: .retryable), now: now)
        #expect(gate.blockedUntil("login", now: now) != nil)
        gate.recordSuccess("login")
        #expect(gate.blockedUntil("login", now: now) == nil)
    }
}
