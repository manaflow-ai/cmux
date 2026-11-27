import CmuxCloud
import Foundation
import Testing

@Suite("Cloud machine access loss")
struct CloudMachineAccessLossTests {
    @Test("404 vm_not_found, 403 and vm_owner_mismatch are permanent")
    func permanentAnswers() {
        #expect(CloudMachineAccessLoss(error: VMClientError.httpStatus(404, #"{"error":"vm_not_found"}"#)) == .notFound)
        #expect(CloudMachineAccessLoss(error: VMClientError.httpStatus(403, #"{"error":"forbidden"}"#)) == .forbidden)
        #expect(CloudMachineAccessLoss(error: VMClientError.httpStatus(403, "")) == .forbidden)
        #expect(CloudMachineAccessLoss(error: VMClientError.httpStatus(409, #"{"error":"vm_owner_mismatch"}"#)) == .ownerMismatch)
    }

    @Test("A revoked Mac sign-in asks for a new sign-in, not a lost machine")
    func revokedSignIn() throws {
        let body = #"{"error":"vm_access_revoked","phase":"network","message":"Cloud access for this Mac login was revoked."}"#
        let loss = try #require(CloudMachineAccessLoss(error: VMClientError.httpStatus(403, body)))
        #expect(loss == .signInRevoked)
        #expect(!loss.isMachineScoped)
        #expect(CloudMachineAccessLoss.forbidden.isMachineScoped)
        #expect(CloudMachineAccessLoss.notFound.isMachineScoped)
        #expect(CloudMachineAccessLoss.ownerMismatch.isMachineScoped)
    }

    @Test("A 403 about a team, a plan or this Mac's network never ends the machine", arguments: [
        #"{"error":"vm_billing_team_not_found","message":"That team is not available for this account."}"#,
        #"{"error":"vm_billing_team_required"}"#,
        #"{"error":"vm_resize_plan_limit","phase":"resize"}"#,
        #"{"error":"vm_bound_token_required"}"#,
        #"{"error":"vm_tunnel_some_future_refusal","phase":"network"}"#,
    ])
    func nonMachineForbidden(body: String) {
        #expect(CloudMachineAccessLoss(error: VMClientError.httpStatus(403, body)) == nil)
    }

    @Test("Transient answers keep automatic reconnects", arguments: [
        VMClientError.httpStatus(404, #"{"error":"route_not_found"}"#),
        VMClientError.httpStatus(404, "not json"),
        VMClientError.httpStatus(409, #"{"error":"vm_access_grant_busy","retryable":true,"retryAfterSeconds":1}"#),
        VMClientError.httpStatus(429, #"{"error":"rate_limited"}"#),
        VMClientError.httpStatus(503, #"{"error":"vm_unavailable"}"#),
        VMClientError.notSignedIn,
        VMClientError.backendUnreachable(url: "http://127.0.0.1:1", detail: "offline"),
    ])
    func transientAnswers(error: VMClientError) {
        #expect(CloudMachineAccessLoss(error: error) == nil)
    }

    @Test("Non-client errors are never permanent")
    func otherErrors() {
        #expect(CloudMachineAccessLoss(error: URLError(.timedOut)) == nil)
        #expect(CloudMachineAccessLoss(error: CancellationError()) == nil)
    }
}
