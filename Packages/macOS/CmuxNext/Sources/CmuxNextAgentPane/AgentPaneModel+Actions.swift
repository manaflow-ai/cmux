extension AgentPaneModel {
    /// The app actions any agent tab may run: the location row's SSH…, New Cloud Machine and Open
    /// Cloud…, which opens the Cloud page at its storefront (`#/get`: the plan's sizes; the pane
    /// knows no plan), Connect Phone…, which opens the Mobile Pairing page, Add Machine… (the Add
    /// Device card: a computer on the tailnet or in ~/.ssh/config, enrolled with its daemon kept
    /// current, or a new Cloud VM), and a started chat's Move to Cloud and Bring Back Local (the tab
    /// menu's same actions, on this tab). webviews environments.ts CONNECT_ACTIONS names the same
    /// seven.
    static let connectActions: Set<String> = [
        "remote.connect", "newCloudMachine", "palette.openCloudPane", "palette.mobileConnect", "device.add", "cloudMove",
        "cloudBringBack",
    ]
    /// The arguments a connect action runs with.
    static let connectArguments: [String: [String: String]] = ["palette.openCloudPane": ["route": "/get"]]
    /// What runs when a connect is refused: signed out, cmux Cloud… starts sign-in.
    static let connectFallbacks: [String: String] = ["newCloudMachine": "palette.auth.signIn"]

    /// `action.run` from the page. Any agent tab may open the New Tab
    /// page (a blank chat's New), the command palette's chats page ("Show all", decision K1), and the
    /// location row's SSH and cmux Cloud connect flows (Lawrence 2026-10-06: "I cannot click on cmux
    /// Cloud SSH"). Integrate a harness is the page's own Harnesses page (cx-uj5g8).
    /// A connect flow opens app UI, so it uses the user's fresh gesture in the pane (the grant
    /// credit, as Choose Folder…); page script cannot make one. Its sign-in fallback runs only
    /// inside that same gesture. An action the app did not run (turned off, or not for this tab), with
    /// no fallback that ran, is an `unavailable` failure, so the page can say so; one that ran and
    /// then stopped reports itself in the app (its refusal or toast).
    func runAction(_ id: String) -> [String: Any] {
        guard id == "newTab.page" || id == "agentPane.searchChats" || Self.connectActions.contains(id),
              let onRunAction else {
            return Self.unsupported("action.run")
        }
        if Self.connectActions.contains(id), !transport.gestures.consume() { return Self.transportFailure(.gestureRequired) }
        if onRunAction(id, Self.connectArguments[id] ?? [:]) { return AgentPaneReply.success() }
        if let fallback = Self.connectFallbacks[id], onRunAction(fallback, [:]) { return AgentPaneReply.success() }
        return AgentPaneReply.failure(code: "unavailable", message: "The app did not run \(id).")
    }
}
