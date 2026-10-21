import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `run.attach` (the Run board's Attach): a redeemed ticket reaches the App only with a live,
/// trusted-carrier `ws`/`wss` endpoint and the person's fresh gesture in the pane; anything else is
/// refused before the App looks for the worker daemon.
@Suite(.serialized)
@MainActor
struct AgentPaneRunAttachTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func params(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var params: [String: Any] = [
            "runId": "run-1", "attemptId": "attempt-1", "provider": "cloud-vm",
            "providerVmId": "vm-1", "providerWorkspaceId": "workspace-1", "providerTerminalId": "terminal-1",
            "route": "wss://vm.example/v1/link", "session": "cloud", "trustedCarrier": true,
            "expiresAtUnix": Date().timeIntervalSince1970 + 300,
        ]
        for (key, value) in overrides { params[key] = value }
        return params
    }

    private static func request(_ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "run.attach", "params": params])
    }

    private static func errorCode(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    @Test func decodesARedeemedTicket() {
        guard case .runAttach(let attach) = Self.request(Self.params()) else {
            Issue.record("run.attach did not decode")
            return
        }
        #expect(attach.providerVMID == "vm-1")
        #expect(attach.providerTerminalID == "terminal-1")
        #expect(attach.session == "cloud")
        #expect(attach.providerWorkspaceID == "workspace-1")
    }

    @Test func refusesExpiredUntrustedOrNonWebSocketEndpoints() {
        let refused: [[String: Any]] = [
            Self.params(["expiresAtUnix": Date().timeIntervalSince1970 - 1]),
            Self.params(["trustedCarrier": false]),
            Self.params(["route": "https://vm.example/v1/link"]),
            Self.params(["providerTerminalId": ""]),
            Self.params(["session": String(repeating: "s", count: 257)]),
        ]
        for params in refused {
            #expect(Self.request(params) == .invalidRunAttach)
        }
    }

    /// The attaches the App was asked for.
    private final class Recorder {
        var attached: [AgentPaneRunAttach] = []
    }

    @Test func attachesOnlyWithAFreshGesture() async {
        let model = AgentPaneModel(host: NoHost())
        let recorder = Recorder()
        model.onRunAttach = { [recorder] in recorder.attached.append($0) }

        let withoutGesture = await model.respond(to: Self.request(Self.params()))
        #expect(Self.errorCode(withoutGesture) == AgentPaneTransportError.gestureRequired.rawValue)
        #expect(recorder.attached.isEmpty)

        model.transport.gestures.record(click: true)
        let withGesture = await model.respond(to: Self.request(Self.params()))
        #expect(withGesture["ok"] as? Bool == true)
        #expect(recorder.attached.map(\.attemptID) == ["attempt-1"])

        // The gesture is used once.
        let again = await model.respond(to: Self.request(Self.params()))
        #expect(Self.errorCode(again) == AgentPaneTransportError.gestureRequired.rawValue)
    }

    @Test func reportsAnInvalidTicketAndAMissingHost() async {
        let model = AgentPaneModel(host: NoHost())
        let invalid = await model.respond(to: Self.request(Self.params(["trustedCarrier": false])))
        #expect(Self.errorCode(invalid) == "run_attach_invalid")
        let unwired = await model.respond(to: Self.request(Self.params()))
        #expect(Self.errorCode(unwired) == "unsupported")
    }
}
