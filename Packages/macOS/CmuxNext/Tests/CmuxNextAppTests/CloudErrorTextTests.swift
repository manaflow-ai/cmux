@testable import CmuxNextApp
@testable import CmuxNextCloud
import CmuxNextCompat
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

    /// The server's own actions (`routeHelpers.ts`) written for an API
    /// caller or the classic `cmux vm` CLI: the app shows the message and
    /// trace id without them; the log (`description`) keeps them.
    @Test(arguments: [
        ("vm_firewall_rule_not_found", "List your rules with GET /api/vm/firewall; a retried delete of a removed rule is already done."),
        ("vm_tunnel_not_found", "Enroll it with POST /api/vm/tunnel, then bring the WireGuard tunnel up."),
        ("vm_not_found", "Run `cmux vm ls` to see available Cloud VMs. If the VM stopped while idle, start a new one with `cmux vm new`."),
        ("vm_access_requires_pro", "Upgrade to Pro at https://cmux.com/pricing to reconnect vm-1, or delete it with `cmux vm rm vm-1`."),
        ("vm_active_limit_exceeded", "Upgrade to cmux Pro at https://cmux.com/pricing for more active machines, or free a slot with `cmux vm rm <id>`."),
        ("vm_network_full", "Delete machines you no longer use with `cmux vm rm <id>`, or revoke Macs you no longer use on the network."),
        ("vm_image_unavailable", "A different machine kind (for example `cmux vm new --base`) may still be available."),
        ("vm_cloud_service_unavailable", "Retry once. If it fails again, run `cmux vm ls` to check whether a VM was created."),
        ("vm_attach_transport_unsupported", "Request the attach endpoint with transport \"cmux-remote\" (supported: cmux-remote), or update cmux."),
    ])
    func anActionForAnAPICallerIsNotShown(code: String, action: String) {
        let error = CloudAPIError.from(status: 409, data: Self.body(["error": code, "message": "It failed.", "action": action, "traceId": "t-1"]),
                                       headerCode: code)
        #expect(error.description == "It failed. \(action) (trace t-1)")
        #expect(CloudStrings.errorText(error) == "It failed. \(CloudStrings.trace("t-1"))")
    }

    /// A paused machine's resume and a creation failure read through the same
    /// text: no `cmux vm` action, no API path from a timeout.
    @Test(.timeLimit(.minutes(1)), arguments: [
        CloudAPIError.http(status: 404, code: "vm_not_found", message: "Cloud VM vm-1 was not found.",
                           action: "Run `cmux vm ls` to see available Cloud VMs.", traceId: "t-2"),
        CloudAPIError.timedOut("POST /api/vm/vm-1/resume"),
    ])
    func aFailedResumeReadsAsTheErrorText(error: CloudAPIError) async {
        let f = CloudIdlePauseTests.pausedMachine(reason: .idle)
        f.session.resumer = { _ in throw error }
        f.session.attach(origin: .user)
        let session = f.session
        for await busy in ObservationStream({ session.resuming }) where !busy { break }
        #expect(f.session.resumeFailure == CloudStrings.errorText(error))
        #expect(f.session.resumeFailure?.contains("cmux vm") == false)
        #expect(f.session.resumeFailure?.contains("/api/vm") == false)
        f.session.disconnect()
    }

    @Test func aFailedCreationReadsAsTheErrorText() {
        let creation = CloudMachineCreation(windowID: nil)
        creation.fail(CloudAPIError.timedOut("POST /api/vm"))
        #expect(creation.phase == .failed(CloudStrings.apiTimedOut))
    }

    /// An action for a person stays, a checkout link under /api/billing included.
    @Test func anActionForAPersonIsShown() {
        let action = "Get more Cloud VM credits at https://cmux.com/api/billing/checkout?plan=pro, or ask a team admin to add some, then retry."
        let error = CloudAPIError.http(status: 402, code: "vm_create_credits_required", message: "Out of credits.", action: action, traceId: nil)
        #expect(CloudStrings.errorText(error) == "Out of credits. \(action)")
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
