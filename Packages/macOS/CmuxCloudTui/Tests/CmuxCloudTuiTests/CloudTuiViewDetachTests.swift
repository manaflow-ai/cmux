import CmuxCloudTui
import CmuxTerminalSizing
import Foundation
import Testing

/// The Mac side of `sizing-view-detach-v1` (docs/shared-terminal-sizing.md):
/// a Cloud terminal's Mac opts in, reads a view-only detach, and reattaches
/// its view without reconnecting.
@Suite struct CloudTuiViewDetachTests {
    private let commands = CloudTuiManualIOCommand()

    @Test func setClientInfoOptsIntoViewDetach() throws {
        let info = commands.setClientInfo(name: "cmux", kind: "mac")
        let capabilities = try #require(info["capabilities"] as? [String])
        #expect(capabilities.contains(commands.sizingViewDetachCapability))
        #expect(commands.sizingViewDetachCapability == "sizing-view-detach-v1")
    }

    @Test func viewOnlyDetachDecodesItsScope() throws {
        let line = Data(#"{"event":"detached","surface":7,"reason":"disconnected-by","by":{"display_name":"Maya","device_name":"Maya's iPhone"},"scope":"view"}"#.utf8)
        let frame = try #require(CloudTuiManualIOFrameDecoder().decode(line))
        let actor = TerminalDetachActor(displayName: "Maya", deviceName: "Maya's iPhone")
        #expect(frame == .detached(surfaceID: 7, reason: .disconnectedBy(actor), view: nil, viewOnly: true))
        let whole = try #require(CloudTuiManualIOFrameDecoder().decode(Data(#"{"event":"detached","surface":7,"reason":"host-shutdown"}"#.utf8)))
        #expect(whole == .detached(surfaceID: 7, reason: .hostShutdown, view: nil, viewOnly: false))
    }

    @Test func detachClientIsScopedToTheTerminal() {
        let command = commands.detachClient(participantID: "c5", surfaceID: 7, by: TerminalDetachActor(displayName: "Maya"), requestID: 3)
        #expect(command["cmd"] as? String == "detach-client")
        #expect(command["client"] as? String == "c5")
        #expect(command["surface"] as? UInt64 == 7)
    }

    @Test func reattachViewCarriesTheViewerChoice() {
        let viewer = commands.reattachView(surfaceID: 7, asViewer: true, requestID: 4)
        #expect(viewer["cmd"] as? String == "reattach-view")
        #expect(viewer["surface"] as? UInt64 == 7)
        #expect(viewer["counts"] as? Bool == false)
        let participant = commands.reattachView(surfaceID: 7, asViewer: false, requestID: 5)
        #expect(participant["counts"] == nil)
    }
}
