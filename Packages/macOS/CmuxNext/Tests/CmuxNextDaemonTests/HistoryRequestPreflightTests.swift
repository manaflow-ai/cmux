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
    func deleteRefusalsReachTheCallerWithoutBecomingRetryable(code: String) async throws {
        let daemon = try DribblingDaemon()
        defer { daemon.stop() }
        let transport = try LineTransport(path: daemon.path)
        defer { transport.close() }
        transport.start(onEvent: { _, _, _ in }, onClose: { _ in })
        let reply = Task {
            try await transport.request(cmd: DeleteTerminalCommandsRequest.command, timeout: .seconds(15)) { id in
                try WireCoding.encodeRequest(DeleteTerminalCommandsRequest(.ids(["1"])), id: id)
            }
        }
        let id = try #require(await daemon.firstRequest())
        let wire = #"{"id":\#(id),"ok":false,"error":"delete refused","error_code":"\#(code)","retryable":false}"#
        daemon.send(Data(wire.utf8) + Data([0x0A]), slices: 1, every: .zero)
        let result = await reply.result
        guard case .failure(let failure) = result, let refusal = failure as? DaemonError else {
            Issue.record("a refused delete must fail the request: \(result)")
            return
        }
        #expect(refusal == .command(cmd: DeleteTerminalCommandsRequest.command,
            message: "delete refused", code: code, details: nil, retryable: false))
        #expect(!refusal.isLostConnection)
        #expect(!refusal.isMissedDeadline)
    }
}
