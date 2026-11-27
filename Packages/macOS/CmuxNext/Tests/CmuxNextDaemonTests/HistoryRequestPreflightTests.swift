import Foundation
import Testing
@testable import CmuxNextDaemon

struct HistoryRequestPreflightTests {
    @Test(arguments: [[], ["terminal-command-history-v10"], ["terminal-command-history-v1"]])
    func legacyListAndDeleteRemainServedWithoutAnAdvertisement(capabilities: [String]) throws {
        let identity = DaemonIdentity(capabilities: capabilities, generation: "history-test")
        // This is the same preflight DaemonConnection.request runs before writing a frame.
        try ListTerminalCommandsRequest.requireServed(by: identity)
        try DeleteTerminalCommandsRequest.requireServed(by: identity)
    }

    @Test func legacyReadsAlsoPreserveUnknownIdentityPreflight() throws {
        try ListTerminalCommandsRequest.requireServed(by: nil)
        try DeleteTerminalCommandsRequest.requireServed(by: nil)
    }

    @Test(arguments: [[], ["terminal-command-history-v10"]])
    func settingsStillRequiresTheExactAdvertisement(capabilities: [String]) {
        let identity = DaemonIdentity(capabilities: capabilities, generation: "history-test")
        #expect(throws: DaemonError.missingCapabilities(["terminal-command-history-v1"])) {
            try SetTerminalCommandHistoryRequest.requireServed(by: identity)
        }
    }

    @Test func settingsRequiresKnownSupport() throws {
        #expect(throws: DaemonError.missingCapabilities(["terminal-command-history-v1"])) {
            try SetTerminalCommandHistoryRequest.requireServed(by: nil)
        }
        try SetTerminalCommandHistoryRequest.requireServed(by:
            DaemonIdentity(capabilities: ["terminal-command-history-v1"], generation: "history-test"))
    }

    @Test(arguments: ["approval_required", "operator_stop", "remote_denied"])
    func deleteRefusalsRetainTheirCodeAndDoNotBecomeRetryable(code: String) throws {
        let wire = #"{"id":7,"ok":false,"error":"delete refused","error_code":"\#(code)","retryable":false}"#
        let envelope = try WireCoding.decoder().decode(LineTransport.Envelope.self, from: Data(wire.utf8))
        #expect(envelope.ok == false)
        #expect(envelope.errorCode == code)
        #expect(envelope.retryable == false)
        let refusal = DaemonError.command(cmd: DeleteTerminalCommandsRequest.command,
            message: try #require(envelope.error), code: envelope.errorCode,
            details: envelope.errorDetails, retryable: envelope.retryable)
        #expect(!refusal.isLostConnection)
        #expect(!refusal.isMissedDeadline)
    }
}
