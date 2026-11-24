extension AgentPaneModel {
    /// The app actions any agent tab may run: the location row's SSH…, New Cloud Machine and Open
    /// Cloud…, which opens the Cloud page at its storefront (`#/get`: the plan's sizes; the pane
    /// knows no plan), Connect Phone…, which opens the Mobile Pairing page, Add Machine… (the Add
    /// Device card: a computer on the tailnet or in ~/.ssh/config, enrolled with its daemon kept
    /// current, or a new Cloud VM), and a started chat's Move to Cloud and Bring Back Local (the tab
    /// menu's same actions, on this tab), and the signed-out picker's Sign in for Cloud
    /// (`palette.auth.signIn`: it signs in and creates no machine). webviews environments.ts
    /// CONNECT_ACTIONS names the same eight. Also the machine header's Reconnect (`machine.reconnect`), which the host runs on
    /// this tab's own machine only (the strip's red machine, picked).
    static let connectActions: Set<String> = [
        "remote.connect", "newCloudMachine", "palette.openCloudPane", "palette.mobileConnect", "device.add", "cloudMove",
        "cloudBringBack", "machine.reconnect", "palette.auth.signIn",
    ]
    /// The arguments a connect action runs with.
    static let connectArguments: [String: [String: String]] = ["palette.openCloudPane": ["route": "/get"]]
    /// The command palette pages any agent tab may open: the chats page (Show all, the + menu's
    /// Search chats) and the History search page (the + menu's Search pages). They open the app's own
    /// palette, as Cmd-K does, so they need no gesture credit.
    static let paletteActions: Set<String> = ["agentPane.searchChats", "history.search"]
    /// The chat folder's actions (the "..." menu's Folder ▸, Session Info, the changed-files card, the worktree
    /// pill): Open in Editor, Open In ▸, Reveal in Finder, Open Terminal Here, Copy Path, on this tab's chat. They
    /// open another app, a tab or write the clipboard, so each spends the person's gesture.
    static let folderActions: Set<String> = [
        "agentPane.openCwdInEditor", "agentPane.openCwdInApp", "agentPane.revealCwdInFinder", "agentPane.openCwdInTerminal",
        "agentPane.copyCwdPath",
    ]
    /// The folder actions that take an `app`: an editor id of the table (``AgentPaneRequest/isEditorID(_:)``).
    static let editorActions: Set<String> = ["agentPane.openCwdInEditor", "agentPane.openCwdInApp"]
    /// New Cloud Chat from a started chat's `/side --on cloud` or `/cd --on cloud` (webviews
    /// commandPlace.ts). It opens a tab, so it spends the person's gesture; its `handoff` is the page's
    /// one-time token, handed to the new tab's page unread (the page keeps what it names).
    static let cloudStartActions: Set<String> = ["palette.newCloudChat"]
    /// The chat menu's Switch to Terminal on half of a terminal and chat pair (``AgentPaneHeaderHooks/switchesToTerminal``,
    /// user 2026-11-20): the app's Toggle Terminal and Chat on this tab, the tab right-click's same row. It shows another
    /// tab, so it spends the person's gesture.
    static let terminalSwitchActions: Set<String> = ["palette.toggleTerminalChat"]
    /// Set Up Computer Use from the chat's "Computer use is not set up" notice (`@computer-use`,
    /// ``AgentPaneComputerUseState``). It opens the onboarding step, so it spends the person's key press or click from
    /// just now (``AgentPaneUserGestures/consumeFreshGesture()``), never the generic half-minute credit.
    static let setupActions: Set<String> = [AgentPaneComputerUseState.setupAction]

    /// A model the person cannot use (Leo 2026-10-26: "if user picks a model they don't have api key,
    /// we offer them to add credits or add their own api key"): Add Credits… takes the one paid-plan
    /// path (``UpgradeToPro``) as the model router's paywall, with its fixed `source`. webviews
    /// accessOffer.ts ACCESS_ACTIONS names the same one. It opens app UI, so it needs the person's gesture.
    static let accessActions: Set<String> = ["palette.pro.upgrade"]
    /// The arguments an access action runs with; the page names none.
    static let accessArguments: [String: [String: String]] = ["palette.pro.upgrade": ["source": "inference"]]

    /// `action.run` from the page. Any agent tab may open the New Tab
    /// page (a blank chat's New), the command palette's chats page ("Show all", decision K1), and the
    /// location row's SSH and cmux Cloud connect flows (Lawrence 2026-10-06: "I cannot click on cmux
    /// Cloud SSH"). Integrate a harness is the page's own Harnesses page (cx-uj5g8).
    /// A connect flow opens app UI, so it uses the user's fresh gesture in the pane (the grant
    /// credit, as Choose Folder…); page script cannot make one. The native creation handler owns
    /// sign-in and its continuation. An action the app did not run (turned off, or not for this tab)
    /// is an `unavailable` failure, so the page can say so, with the app's reason when it gave one
    /// (``AgentPaneActionRun/refused(_:)``); one that ran and then stopped reports itself in the app
    /// (its own toast).
    func runAction(_ id: String, session: String? = nil, environment: String? = nil, handoff: String? = nil, app: String? = nil) -> [String: Any] {
        let screenShare = id == "session.screenShare"
        let gated = Self.connectActions.contains(id) || Self.accessActions.contains(id) || Self.cloudStartActions.contains(id)
            || Self.terminalSwitchActions.contains(id) || Self.folderActions.contains(id) || Self.setupActions.contains(id)
            || screenShare
        guard id == "newTab.page" || Self.paletteActions.contains(id) || gated, let onRunAction else {
            return Self.unsupported("action.run")
        }
        // Bound to the chat whose menu offered it: a tab that shows another chat by now runs nothing.
        if let session, header?.showsChat(session) != true {
            return Self.refused("This chat is no longer shown.")
        }
        if gated, !(Self.setupActions.contains(id) ? transport.gestures.consumeFreshGesture() : transport.gestures.consume()) {
            return Self.transportFailure(.gestureRequired)
        }
        var arguments = Self.connectArguments[id] ?? Self.accessArguments[id] ?? [:]
        if screenShare, let session { arguments["session"] = session }
        if let environment { arguments["environment"] = environment }
        if let handoff { arguments["handoff"] = handoff }
        if let app, Self.editorActions.contains(id) { arguments["app"] = app }
        switch onRunAction(id, arguments) {
        case .ran: return AgentPaneReply.success()
        case .refused(let reason): return Self.refused(reason)
        case .notRun: return AgentPaneReply.failure(code: "unavailable", message: "The app did not run \(id).")
        }
    }

    /// An `unavailable` failure that carries the reason the person reads (`details.reason`): the page's
    /// toast says it (webviews actionRefusal.ts), never a generic "couldn't start".
    static func refused(_ reason: String) -> [String: Any] {
        AgentPaneReply.failure(code: "unavailable", message: reason, details: ["reason": reason], retryable: false, origin: "native")
    }
}

/// What the app did with a page's `action.run`: ran it; refused it with the reason the person reads
/// (Move to Cloud on a chat with no first message: "Send a first message, then move this chat."); or
/// did not run it with no reason to give (turned off, not for this tab).
public enum AgentPaneActionRun: Equatable, Sendable {
    case ran
    case refused(String)
    case notRun
}
