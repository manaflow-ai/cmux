import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A cmux app link clicked in an agent chat (`cmux://workspace/ws_…`) leaves the pane to the app's
/// own link opener after a real gesture, and never to the system's URL handler.
@MainActor
struct AgentPaneAppLinkTests {
    private let source = AgentPaneSource.bundled(URL(string: "cmux-agent://pane/index.html")!)
    private let workspace = URL(string: "cmux://workspace/ws_0123456789abcdef0123456789abcdef")!

    @Test func aClickedAppLinkLeavesThePaneAndAnUnclickedOneIsCancelled() {
        #expect(AgentPaneNavigation.decision(for: workspace, source: source, userClicked: true) == .openOutside(workspace))
        #expect(AgentPaneNavigation.decision(for: workspace, source: source, userClicked: false) == .cancel)
        let ssh = URL(string: "ssh://host")!
        #expect(AgentPaneNavigation.decision(for: ssh, source: source, userClicked: true) == .cancel)
        let script = URL(string: "javascript:alert(1)")!
        #expect(AgentPaneNavigation.decision(for: script, source: source, userClicked: true) == .cancel)
    }

    @Test func anAppLinkGoesToTheAppOpenerOnlyWithAGesture() {
        let gestures = AgentPaneUserGestures()
        var system: [URL] = [], app: [URL] = []
        #expect(!AgentPaneNavigation.openOutside(workspace, gestures: gestures, open: { system.append($0) },
                                                 openApp: { app.append($0); return true }))
        #expect(app.isEmpty, "a link opened with no gesture")
        gestures.record(click: true)
        #expect(AgentPaneNavigation.openOutside(workspace, gestures: gestures, open: { system.append($0) },
                                                openApp: { app.append($0); return true }))
        #expect(app == [workspace])
        #expect(system.isEmpty, "an app link went to the system")
    }

    @Test func onlyCmuxSchemesWithAKnownHostAreAppLinks() {
        #expect(AgentPaneNavigation.isCmuxAppLink(workspace))
        #expect(AgentPaneNavigation.isCmuxAppLink(URL(string: "cmux-dev-tag://session/abc")!))
        #expect(!AgentPaneNavigation.isCmuxAppLink(URL(string: "cmux://auth-callback")!))
        #expect(!AgentPaneNavigation.isCmuxAppLink(URL(string: "cmux://u:p@workspace/ws_x")!))
        #expect(!AgentPaneNavigation.isCmuxAppLink(URL(string: "https://workspace/ws_x")!))
    }
}
