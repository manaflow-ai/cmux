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

    /// A model the person cannot use (Leo 2026-10-26: "if user picks a model they don't have api key,
    /// we offer them to add credits or add their own api key"): Add API Key… opens Settings >
    /// Accounts, at the provider's key field when the page names one, and Add Credits… takes the one
    /// paid-plan path (``UpgradeToPro``) as the model router's paywall. webviews accessOffer.ts
    /// ACCESS_ACTIONS names the same two. Each opens app UI, so each needs the person's gesture.
    static let accessActions: Set<String> = ["accounts.show", "palette.pro.upgrade"]
    /// The arguments an access action runs with, beside what the page names.
    static let accessArguments: [String: [String: String]] = ["palette.pro.upgrade": ["source": "inference"]]

    /// The arguments the page may name for `id`: a provider for Accounts, a short lowercase name
    /// (`anthropic`, `openai`); anything else is dropped. The Accounts action checks it is a provider.
    static func pageArguments(for id: String, _ arguments: [String: String]) -> [String: String] {
        guard id == "accounts.show", let provider = arguments["provider"], !provider.isEmpty, provider.count <= 32,
              provider.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }) else { return [:] }
        return ["provider": provider]
    }

    /// `action.run` from the page. Any agent tab may open the New Tab
    /// page (a blank chat's New), the command palette's chats page ("Show all", decision K1), and the
    /// location row's SSH and cmux Cloud connect flows (Lawrence 2026-10-06: "I cannot click on cmux
    /// Cloud SSH"). Integrate a harness is the page's own Harnesses page (cx-uj5g8).
    /// A connect flow opens app UI, so it uses the user's fresh gesture in the pane (the grant
    /// credit, as Choose Folder…); page script cannot make one. Its sign-in fallback runs only
    /// inside that same gesture. An action the app did not run (turned off, or not for this tab), with
    /// no fallback that ran, is an `unavailable` failure, so the page can say so; one that ran and
    /// then stopped reports itself in the app (its refusal or toast).
    func runAction(_ id: String, arguments: [String: String] = [:]) -> [String: Any] {
        let gated = Self.connectActions.contains(id) || Self.accessActions.contains(id)
        guard id == "newTab.page" || id == "agentPane.searchChats" || gated, let onRunAction else {
            return Self.unsupported("action.run")
        }
        if gated, !transport.gestures.consume() { return Self.transportFailure(.gestureRequired) }
        let fixed = Self.connectArguments[id] ?? Self.accessArguments[id] ?? [:]
        if onRunAction(id, Self.pageArguments(for: id, arguments).merging(fixed) { _, own in own }) { return AgentPaneReply.success() }
        if let fallback = Self.connectFallbacks[id], onRunAction(fallback, [:]) { return AgentPaneReply.success() }
        return AgentPaneReply.failure(code: "unavailable", message: "The app did not run \(id).")
    }
}
