@testable import CmuxNextApp
@testable import CmuxNextCloud
import Foundation
import Testing

/// A Cloud failure reads as what failed and the next step, never a Swift
/// dump. The `/api/vm` error body's `action` ("Run `…`") and `traceId`
/// (`web/services/vms/routeHelpers.ts` `vmErrorResponse`) reach the person;
/// before, `CloudAPIError.from` kept only the message.
@MainActor
struct CloudErrorTextTests {
    static func body(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    @Test func theServerActionAndTraceIDFollowTheMessage() {
        let error = CloudAPIError.from(status: 409, data: Self.body([
            "error": "vm_resize_in_progress", "message": "raw", "action": "Wait for the current resize to finish, then retry.",
            "traceId": "abc123", "ui": ["message": "Cloud VM vm-1 is already resizing.", "traceId": "abc123"],
        ]), headerCode: nil)
        #expect(error == .http(status: 409, code: "vm_resize_in_progress", message: "Cloud VM vm-1 is already resizing.",
                               action: "Wait for the current resize to finish, then retry.", traceId: "abc123"))
        #expect(error.description == "Cloud VM vm-1 is already resizing. Wait for the current resize to finish, then retry. (trace abc123)")
        #expect(CloudStrings.errorText(error)
            == "Cloud VM vm-1 is already resizing. Wait for the current resize to finish, then retry. \(CloudStrings.trace("abc123"))")
    }

    /// The server's own payloads (`routeHelpers.ts`) whose action is written
    /// for an API caller or the classic CLI: the app shows the message and
    /// trace id without it; the log (`description`) keeps it.
    @Test(arguments: [
        ("vm_firewall_rule_not_found", "This firewall rule is not in your Cloud VM network.",
         "List your rules with GET /api/vm/firewall; a retried delete of a removed rule is already done."),
        ("vm_tunnel_not_found", "This computer is not enrolled on your Cloud VM network.",
         "Enroll it with POST /api/vm/tunnel, then bring the WireGuard tunnel up."),
        ("vm_not_found", "Cloud VM vm-1 was not found.",
         "Run `cmux vm ls` to see available Cloud VMs. If the VM stopped while idle, start a new one with `cmux vm new`."),
    ])
    func anActionForAnAPICallerIsNotShown(code: String, message: String, action: String) {
        let error = CloudAPIError.from(status: 404, data: Self.body(["error": code, "message": message, "action": action, "traceId": "t-1"]),
                                       headerCode: code)
        #expect(error.description == "\(message) \(action) (trace t-1)")
        #expect(CloudStrings.errorText(error) == "\(message) \(CloudStrings.trace("t-1"))")
        #expect(CloudStrings.callerOnlyActions.contains(code))
    }

    @Test func aBodyWithoutActionOrTraceReadsAsBefore() {
        let error = CloudAPIError.from(status: 409, data: Self.body(["error": "busy", "message": "Resize in progress.", "action": "  "]),
                                       headerCode: "vm_resize_in_progress")
        #expect(error == .http(status: 409, code: "vm_resize_in_progress", message: "Resize in progress."))
        #expect(error.description == "Resize in progress.")
        #expect(CloudAPIError.from(status: 502, data: Data("<html>".utf8), headerCode: nil).description == "HTTP 502")
    }

    @Test func theUITraceIDIsKeptWhenTheTopLevelOneIsMissing() {
        let error = CloudAPIError.from(status: 500, data: Self.body(["error": "internal", "ui": ["message": "Try again.", "traceId": "t-9"]]),
                                       headerCode: nil)
        #expect(error.text(trace: { "[\($0)]" }) == "Try again. [t-9]")
    }

    @Test func theOtherAPIFailuresSayWhatToDoWithoutAnAPIPath() {
        #expect(CloudStrings.errorText(CloudAPIError.notSignedIn) == CloudStrings.signInFirst)
        #expect(CloudStrings.errorText(CloudAPIError.noBackend(URL(string: "http://127.0.0.1:1")!)) == CloudStrings.localBackend)
        #expect(CloudStrings.errorText(CloudAPIError.timedOut("/api/vm")) == CloudStrings.apiTimedOut)
        #expect(!CloudStrings.apiTimedOut.contains("/api/"))
        #expect(CloudStrings.errorText(CloudAPIError.transport("offline")) == CloudStrings.apiUnreachable("offline"))
        #expect(CloudStrings.errorText(CloudAPIError.decoding("keyNotFound(…)")) == CloudStrings.apiUnreadable)
    }

    @Test func theApprovalsRouteKeepsTheServerActionAndTrace() {
        let error = CloudAPIError.http(status: 409, code: "vm_other", message: "Busy.", action: "Retry in a minute.", traceId: "t1")
        #expect(CloudService.approvalsFailure(error) == .failed("Busy. Retry in a minute. \(CloudStrings.trace("t1"))"))
        #expect(CloudService.workerApprovalsFailure(error) == .failed("Busy. Retry in a minute. \(CloudStrings.trace("t1"))"))
        #expect(CloudService.approvalsFailure(.timedOut("/api/vm/x/acpmux/keyed-start")) == .failed(CloudStrings.apiTimedOut))
        #expect(CloudService.workerApprovalsFailure(.decoding("keyNotFound(…)")) == .failed(CloudStrings.apiUnreadable))
        #expect(CloudService.approvalsFailure(.notSignedIn) == .failed(CloudStrings.signInFirst))
    }

    @Test func anActionFailureReadsAsItsMessage() {
        #expect(CloudStrings.errorText(ActionFailure(message: "No Cloud machine is selected.")) == "No Cloud machine is selected.")
    }
}
