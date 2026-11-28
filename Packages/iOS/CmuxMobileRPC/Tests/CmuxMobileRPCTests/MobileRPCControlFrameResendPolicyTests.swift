import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

/// A request stranded on a replaced control stream may already have been
/// applied by the host. Only requests whose second application is harmless
/// may be sent again.
@Suite struct MobileRPCControlFrameResendPolicyTests {
    private func frame(method: String, params: [String: Any] = [:]) throws -> Data {
        try MobileSyncFrameCodec.encodeFrame(
            MobileCoreRPCClient.requestData(method: method, params: params, id: "request-1")
        )
    }

    @Test func readOnlyRequestsAreResent() throws {
        #expect(MobileRPCControlFrameResendPolicy.allowsResend(ofFrame: try frame(method: "mobile.workspace.list")))
        #expect(MobileRPCControlFrameResendPolicy.allowsResend(ofFrame: try frame(method: "mobile.host.status")))
        #expect(MobileRPCControlFrameResendPolicy.allowsResend(ofFrame: try frame(
            method: "mobile.terminal.replay",
            params: ["workspace_id": "w", "surface_id": "s"]
        )))
    }

    @Test func mutationsAndUnknownMethodsAreNeverResent() throws {
        for method in ["terminal.input", "terminal.paste", "workspace.create", "workspace.close",
                       "mobile.terminal.viewport", "mobile.events.subscribe", "some.future.method"] {
            #expect(!MobileRPCControlFrameResendPolicy.allowsResend(ofFrame: try frame(method: method)))
        }
    }

    /// A replay that reports a viewport resizes the terminal first; resending
    /// a stale one could undo a newer size.
    @Test func aReplayCarryingAViewportReportIsNotResent() throws {
        #expect(!MobileRPCControlFrameResendPolicy.allowsResend(ofFrame: try frame(
            method: "mobile.terminal.replay",
            params: ["surface_id": "s", "client_id": "c", "viewport_columns": 80, "viewport_rows": 24]
        )))
    }

    @Test func malformedFramesAreNotResent() {
        #expect(!MobileRPCControlFrameResendPolicy.allowsResend(ofFrame: Data([0, 0, 0, 2, 0x7B, 0x7D])))
        #expect(!MobileRPCControlFrameResendPolicy.allowsResend(ofFrame: Data([0, 0])))
    }
}
