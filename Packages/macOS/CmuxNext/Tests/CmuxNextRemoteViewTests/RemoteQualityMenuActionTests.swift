import AppKit
@testable import CmuxNextRemoteView
import Foundation
import Testing

// The API under test is DEBUG-only, so `swift test -c release` skips this file.
#if DEBUG

/// The Screen Sharing toolbar's Quality menu runs the palette's Set Screen Sharing Quality… (`remote.setQuality`):
/// a row goes to the owner's `pickQuality` (the App runs the action, which calls `selectQuality`), so the menu and the
/// palette run one handler. With no owner hook the row still applies itself.
@MainActor
@Suite struct RemoteQualityMenuActionTests {
    private func pane() -> RemoteDesktopPane {
        RemoteDesktopPane(hostName: "vm", source: MockRemoteStreamSource(status: RemoteViewStatus(state: .streaming)),
                          inputSink: nil, initialMode: .view)
    }

    @Test func aQualityRowRunsTheOwnersAction() throws {
        let pane = pane()
        var picked: [RemoteQualityPreset] = []
        var sent: [RemoteQualityPreset] = []
        pane.handlers.pickQuality = { picked.append($0) }
        pane.handlers.selectQuality = { sent.append($0) }
        let row = try #require(pane.view.toolbar.onSelectQuality)
        row(.sharpText)
        #expect(picked == [.sharpText], "the Quality menu's row did not run remote.setQuality")
        #expect(pane.settings.quality == .auto && sent.isEmpty, "the row applied itself besides the action")

        // What the action runs.
        pane.selectQuality(.sharpText)
        #expect(pane.settings.quality == .sharpText)
        #expect(sent == [.sharpText])
    }

    @Test func withNoOwnerHookTheRowAppliesItself() throws {
        let pane = pane()
        var sent: [RemoteQualityPreset] = []
        pane.handlers.selectQuality = { sent.append($0) }
        let row = try #require(pane.view.toolbar.onSelectQuality)
        row(.lowBandwidth)
        #expect(pane.settings.quality == .lowBandwidth)
        #expect(sent == [.lowBandwidth])
    }
}
#endif
