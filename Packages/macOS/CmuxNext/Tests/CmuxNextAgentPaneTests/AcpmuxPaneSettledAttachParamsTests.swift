import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A cold chat open asks `_acpmux/attach` for acpmux's settled view (`settled: true`, webviews
/// direct.ts `sendAttach`, cmux#41760) whenever the daemon names `settled-attach-v1`. The params
/// rule did not know `settled`, so the host refused every such attach as `transport.intent_invalid`
/// and no chat opened or started after the daemon restarted with the capability (cmux#42185).
@Suite
struct AcpmuxPaneSettledAttachParamsTests {
    private static func attach(_ params: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": 1, "method": "_acpmux/attach", "params": params]
    }

    /// The attach direct.ts `sendAttach` sends on a cold open, exactly.
    private static let openParams: [String: Any] = [
        "sessionId": "s", "waitLogs": false, "limit": 400, "maxBytes": 131_072,
        "kinds": ["transcript"], "eventStream": true, "visible": true,
    ]

    @Test func aSettledColdOpenPassesTheParamsRule() {
        var params = Self.openParams
        params["settled"] = true
        #expect(!AcpmuxPaneMethods.breaksParamsRule(Self.attach(params), modeFields: nil))
    }

    @Test func thePlainRetryStillPasses() {
        #expect(!AcpmuxPaneMethods.breaksParamsRule(Self.attach(Self.openParams), modeFields: nil))
    }

    @Test func anotherKeyOnAttachIsStillRefused() {
        var params = Self.openParams
        params["host"] = "peer"
        #expect(AcpmuxPaneMethods.breaksParamsRule(Self.attach(params), modeFields: nil))
    }
}
