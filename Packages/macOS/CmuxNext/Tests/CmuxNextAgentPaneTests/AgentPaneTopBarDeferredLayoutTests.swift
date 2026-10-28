import AppKit
import CmuxNextPages
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The New Tab bar showing or leaving marks the pane, and the page takes the rest
/// of the pane in the window's next pass (Chrome lays out once per frame; a forced layout needs a
/// read in the turn). Before, every bar update laid the whole pane out in its own turn.
@Suite(.serialized)
@MainActor
struct AgentPaneTopBarDeferredLayoutTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func aBarUpdateLaysOutInTheWindowsPass() throws {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(mainThread: .standalone(), model: AgentPaneModel(host: NoHost()), work: BackgroundWork(label: "test.agent-pane"),
                                              source: .bundled(file), webUI: .agentPaneTestHost(), gestures: .testing()))
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        // sync-layout: the test starts from a laid-out pane, so a later needsLayout is the bar's own.
        view.layoutSubtreeIfNeeded()
        let bar = NSView()
        view.topBar.set(bar, height: 40)
        #expect(view.needsLayout, "the bar's update forced a layout of the pane in its own turn")
        #expect(bar.frame.width == 800 && bar.frame.height == 40, "the bar is placed in the update's turn")
    }
}
