extension AgentPaneModel {
    /// The app actions any agent tab may run: the location row's SSH… and cmux Cloud….
    static let connectActions: Set<String> = ["remote.connect", "newCloudMachine"]
    /// The model picker's + (Add agent…): opens Settings > Agents > Add, app UI like a connect flow.
    static let addAgentAction = "agent.harness.add"
    /// What runs when a connect is refused: signed out, cmux Cloud… starts sign-in.
    static let connectFallbacks: [String: String] = ["newCloudMachine": "palette.auth.signIn"]

    /// `action.run` from the page. Any agent tab may open the New Tab
    /// page (a blank chat's New), the command palette's chats page ("Show all", decision K1), and the
    /// location row's SSH and cmux Cloud connect flows (Lawrence 2026-10-06: "I cannot click on cmux
    /// Cloud SSH"). The New Tab page also runs Add Harness… ("Integrate a harness").
    /// A connect flow opens app UI, so it uses the user's fresh gesture in the pane (the grant
    /// credit, as Choose Folder…); page script cannot make one. Its sign-in fallback runs only
    /// inside that same gesture.
    func runAction(_ id: String) -> [String: Any] {
        guard id == "newTab.page" || id == "agentPane.searchChats" || Self.connectActions.contains(id) || id == Self.addAgentAction
                || (id == "palette.addHarness" && newTab != nil)
                || newTab?.tools.contains(where: { $0.id == id || $0.menu.contains(id) }) == true,
              let onRunAction else {
            return Self.unsupported("action.run")
        }
        if Self.connectActions.contains(id) || id == Self.addAgentAction, !transport.gestures.consume() {
            return Self.transportFailure(.gestureRequired)
        }
        if !onRunAction(id), let fallback = Self.connectFallbacks[id] { _ = onRunAction(fallback) }
        return AgentPaneReply.success()
    }
}
