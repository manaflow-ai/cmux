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
        let error = CloudAPIError.from(status: 404, data: Self.body([
            "error": "vm_not_found", "message": "raw", "action": "Run `cmux cloud list-machines`.", "traceId": "abc123",
            "ui": ["message": "Cloud VM vm-1 was not found.", "traceId": "abc123"],
        ]), headerCode: nil)
        #expect(error == .http(status: 404, code: "vm_not_found", message: "Cloud VM vm-1 was not found.",
                               action: "Run `cmux cloud list-machines`.", traceId: "abc123"))
        #expect(error.description == "Cloud VM vm-1 was not found. Run `cmux cloud list-machines`. (trace abc123)")
        #expect(CloudStrings.errorText(error)
            == "Cloud VM vm-1 was not found. Run `cmux cloud list-machines`. \(CloudStrings.trace("abc123"))")
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
    }

    @Test func anActionFailureReadsAsItsMessage() {
        #expect(CloudStrings.errorText(ActionFailure(message: "No Cloud machine is selected.")) == "No Cloud machine is selected.")
    }
}
