extension AgentPaneModel {
    /// The app actions any agent tab may run: the location row's SSH… and cmux Cloud….
    static let connectActions: Set<String> = ["remote.connect", "newCloudMachine"]
    /// What runs when a connect is refused: signed out, cmux Cloud… starts sign-in.
    static let connectFallbacks: [String: String] = ["newCloudMachine": "palette.auth.signIn"]

    /// `action.run` from the page. The page runs Import and Sync; any agent tab may open the New Tab
    /// page (a blank chat's New), the command palette's chats page ("Show all", decision K1), and the
    /// location row's SSH and cmux Cloud connect flows (Lawrence 2026-10-06: "I cannot click on cmux
    /// Cloud SSH"). The New Tab page also runs Add Harness… ("Integrate a harness").
    /// A connect flow opens app UI, so it uses the user's fresh gesture in the pane (the grant
    /// credit, as Choose Folder…); page script cannot make one. Its sign-in fallback runs only
    /// inside that same gesture.
    func runAction(_ id: String) -> [String: Any] {
        guard id == "newTab.page" || id == "agentPane.searchChats" || Self.connectActions.contains(id)
                || ((id == "palette.welcomeChecklist" || id == "palette.addHarness") && newTab != nil),
              let onRunAction else {
            return Self.unsupported("action.run")
        }
        if Self.connectActions.contains(id), !transport.gestures.consume() {
            return Self.transportFailure(.gestureRequired)
        }
        if !onRunAction(id), let fallback = Self.connectFallbacks[id] { _ = onRunAction(fallback) }
        return AgentPaneReply.success()
    }
}
