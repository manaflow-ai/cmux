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

    @Test("Transient answers keep automatic reconnects", arguments: [
        VMClientError.httpStatus(404, #"{"error":"route_not_found"}"#),
        VMClientError.httpStatus(404, "not json"),
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
