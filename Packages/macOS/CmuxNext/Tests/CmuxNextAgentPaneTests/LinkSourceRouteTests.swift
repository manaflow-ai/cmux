import CmuxNextAgentPane
import Testing

/// A link a terminal program opens (`browser.open_link`, gh's "Press Enter to open
/// https://github.com/login/device in your browser") starts from the caller's tab. When no window
/// shows that tab's workspace, the tab opens there in the background, never in the pane the
/// person is looking at in another workspace.
@Suite struct LinkSourceRouteTests {
    private func route(_ key: String?, shown: [String: String] = [:], tabs: Set<String> = [], focused: String? = "focused-pane") -> LinkSourceRoute<String> {
        LinkSourceRoute.resolve(key: key, shown: { shown[$0] }, exists: { tabs.contains($0) }, focused: { focused })
    }

    @Test func aTabAWindowShowsOpensFromItsPane() {
        guard case .shown(let pane) = route("tab_a", shown: ["tab_a": "pane_a"], tabs: ["tab_a"]) else { Issue.record("expected shown"); return }
        #expect(pane == "pane_a")
    }

    @Test func aTabNoWindowShowsOpensInItsOwnWorkspaceNotTheFocusedPane() {
        guard case .hidden(let tab) = route("tab_hidden", tabs: ["tab_hidden"]) else {
            Issue.record("expected hidden, got \(route("tab_hidden", tabs: ["tab_hidden"]))")
            return
        }
        #expect(tab == "tab_hidden")
    }

    @Test func aGoneTabOpensNowhereInCmux() {
        guard case .none = route("tab_gone") else { Issue.record("expected none, got \(route("tab_gone"))"); return }
    }

    @Test func noTabNamedOpensFromTheFocusedPane() {
        guard case .focused(let pane) = route(nil) else { Issue.record("expected focused"); return }
        #expect(pane == "focused-pane")
        guard case .none = route(nil, focused: nil) else { Issue.record("expected none"); return }
    }
}
