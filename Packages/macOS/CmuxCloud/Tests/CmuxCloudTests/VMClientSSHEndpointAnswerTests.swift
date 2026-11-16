@testable import CmuxCloud
import Foundation
import Testing

/// `cmux vm ssh` and `cmux vm ssh-info` call `POST /api/vm/:id/ssh-endpoint`.
/// The cmux.com backend removed that route (the managed API has no SSH
/// credential endpoint; web/services/vms/README.md provider matrix), so it
/// answers a route-level 404. Read as an ordinary 404, that became "The
/// requested Cloud VM was not found.", which also stopped `vm ssh` from taking
/// its managed-route fallback (#21754). The answer must classify as an
/// unsupported legacy endpoint, while a real `vm_not_found` stays a not-found.
@Suite("VM SSH endpoint answer classification")
struct VMClientSSHEndpointAnswerTests {
    @Test("a route-level 404 is an unsupported SSH endpoint")
    func routeMissing404IsUnsupported() {
        let html = "<!DOCTYPE html><html><body>404: This page could not be found.</body></html>"
        guard case .sshEndpointUnsupported? = VMClientError.classifySSHEndpointAnswer(status: 404, body: html) else {
            Issue.record("a route-level 404 must classify as sshEndpointUnsupported")
            return
        }
    }

    @Test("a 404 naming vm_not_found stays a not-found")
    func vmNotFoundStaysNotFound() {
        let body = #"{"error":"vm_not_found","message":"Cloud VM not found."}"#
        #expect(VMClientError.classifySSHEndpointAnswer(status: 404, body: body) == nil)
    }

    @Test("other statuses are left to ensureOK", arguments: [200, 401, 403, 409, 429, 500, 501, 503])
    func otherStatusesUnclassified(status: Int) {
        #expect(VMClientError.classifySSHEndpointAnswer(status: status, body: "") == nil)
    }

    @Test("the unsupported answer carries the managed-route fallback code")
    func unsupportedCarriesFallbackCode() {
        #expect(VMClientError.sshEndpointUnsupported.fallbackBackendCode == "vm_attach_transport_unsupported")
    }

    /// The CLI refuses its managed-route fallback when the message reads as a
    /// missing VM (`isVMNotFoundError` matches "was not found" / "vm_not_found").
    @Test("the unsupported message does not read as a missing VM")
    func unsupportedMessageIsNotNotFound() {
        let text = VMClientError.sshEndpointUnsupported.description.lowercased()
        #expect(!text.contains("was not found"))
        #expect(!text.contains("vm_not_found"))
    }
}
