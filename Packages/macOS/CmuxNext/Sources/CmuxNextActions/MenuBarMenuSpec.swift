import Foundation

/// The menu bar menu, top to bottom (user 2026-10-27, after Raycast's menu; user 2026-11-06: "for
/// our computer use i imagine w'll also want to maybe have something similar to this in our top
/// right menu button situation"): Computer Use, the Unread and Running chats, the account, the
/// agents that work or wait, opening cmux, help, cmux's community, the app, logs, then Sign Out
/// and Quit.
///
/// Every fixed row runs a registry action, so the palette, the Help menu and this menu share one
/// path; a chat row is a ``Command`` the App runs on one chat. A row
/// whose action the build does not bind is left out, and so is a section left with no row.
/// The rows are values (``items(for:isBound:)``), so tests read them without AppKit;
/// ``MenuBarMenuBuilder`` turns them into an `NSMenu`. Rust lays them out (cmux-action-catalog
/// `status_menus`, op `menu_bar_items`); this side sends the state and reads the rows back.
public nonisolated struct MenuBarMenuSpec: Sendable {
    /// One row of the menu.
    public enum Item: Sendable, Hashable {
        /// A line that is not a command (who is signed in, how many agents work), with an
        /// optional SF Symbol; `avatar` marks the line that shows the account's picture.
        case info(String, symbol: String?, avatar: Bool)
        /// A registry row: `title` nil keeps the action's own title.
        case action(ActionID, title: String?, symbol: String)
        /// A line that opens Settings at the row `key` names (`openSettings setting:`).
        case setting(String, key: String, symbol: String)
        /// A divider between two sections.
        case separator
        /// A section's title (Unread, Running), a native section header.
        case header(String)
        /// An agent chat: a click opens it in its workspace.
        case chat(MenuBarMenuState.Chat)
        /// A row that runs on one session, not a registry action.
        case command(Command, title: String, symbol: String)
        /// A registry action run on one Computer Use session (its `session` argument), indented
        /// under the session's line.
        case sessionAction(ActionID, session: String, title: String, symbol: String)
        /// The Computer Use row: `app` (its name and bundle id, for the icon) is what it drives,
        /// nil when nothing does; `items` is its submenu.
        case computerUse(app: String?, bundleID: String?, items: [Item])
    }

    /// What a ``Item/command(_:title:symbol:)`` row does.
    public enum Command: Sendable, Hashable {
        /// Opens the chat (an acpmux session id) in its workspace.
        case openChat(String)
        /// Lets a Computer Use session the person stopped act again (the engine's session key).
        case computerUseResume(String)
        /// Rings the session's agent cursor where it is, so the person finds it.
        case computerUseShowCursor(String)
        /// Shows (true) or hides (false) the floating live preview panel (`computerUse.floatingPreview`).
        case computerUseFloatingPreview(Bool)
    }

    /// The most Computer Use sessions the row's submenu names.
    public static let computerUseSessionLimit = 5

    /// The most chats one list shows; the rest are behind More….
    public static let chatLimit = 8

    public init() {}

    /// The rows for `state`, with unbound actions and empty sections left out and one separator
    /// between two sections.
    ///
    /// - Parameters:
    ///   - state: What the menu shows besides its fixed rows.
    ///   - isBound: Whether the build binds an action (`ActionRegistry.action(for:)`).
    /// - Returns: The rows, never starting or ending with a separator.
    public func items(for state: MenuBarMenuState, isBound: (ActionID) -> Bool) -> [Item] {
        let request: [String: Any] = [
            "op": "menu_bar_items", "state": state.json, "locale": Bundle.localizedModule.preferredLocalizations.first ?? "",
            "bound": Self.actionIDs.filter { isBound(ActionID(rawValue: $0)) },
        ]
        return (ActionCatalogRust.call(request)?["items"] as? [Any] ?? []).compactMap(Item.init(row:))
    }

    /// Every action a row can run (op `menu_bar_action_ids`), so the registry is asked about these alone.
    private static let actionIDs = ActionCatalogRust.call(["op": "menu_bar_action_ids"])?["ids"] as? [String] ?? []

    static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "ProfileActions", bundle: .localizedModule)
    }
}

nonisolated extension MenuBarMenuSpec.Item {
    /// The row a Rust row holds (one key per row, the header of status_menus.rs), nil when it is not one.
    init?(row: Any) {
        guard let node = row as? [String: Any], node.count == 1, let (tag, body) = node.first else { return nil }
        let fields = body as? [String: Any] ?? [:]
        let string = { (key: String) in fields[key] as? String }
        let title = string("title") ?? "", symbol = string("symbol") ?? ""
        switch tag {
        case "info": self = .info(string("text") ?? "", symbol: string("symbol"), avatar: fields["avatar"] as? Bool ?? false)
        case "action": guard let id = string("id") else { return nil }; self = .action(ActionID(rawValue: id), title: string("title"), symbol: symbol)
        case "setting": self = .setting(string("text") ?? "", key: string("key") ?? "", symbol: symbol)
        case "separator": self = .separator
        case "header": self = .header(body as? String ?? "")
        case "chat": guard let id = string("id") else { return nil }; self = .chat(.init(id: id, title: title, harness: string("harness")))
        case "sessionAction":
            guard let id = string("id"), let session = string("session") else { return nil }
            self = .sessionAction(ActionID(rawValue: id), session: session, title: title, symbol: symbol)
        case "command":
            let target = string("target") ?? ""
            switch string("command") {
            case "openChat": self = .command(.openChat(target), title: title, symbol: symbol)
            case "computerUseResume": self = .command(.computerUseResume(target), title: title, symbol: symbol)
            case "computerUseShowCursor": self = .command(.computerUseShowCursor(target), title: title, symbol: symbol)
            case "computerUseFloatingPreview": self = .command(.computerUseFloatingPreview(target == "true"), title: title, symbol: symbol)
            default: return nil
            }
        case "computerUse":
            self = .computerUse(app: string("app"), bundleID: string("bundleID"),
                                items: (fields["items"] as? [Any] ?? []).compactMap(Self.init(row:)))
        default: return nil
        }
    }
}

nonisolated extension MenuBarMenuState {
    /// The state as `menu_bar_items` reads it (status_menus.rs `MenuBarMenuState`); nil fields are left out.
    var json: [String: Any] {
        func object(_ pairs: [String: Any?]) -> [String: Any] { pairs.compactMapValues { $0 } }
        func chats(_ list: Chats) -> [String: Any] {
            ["shown": list.shown.map { chat in object(["id": chat.id, "title": chat.title, "harness": chat.harness]) }, "more": list.more]
        }
        var out: [String: Any] = [
            "unread": chats(unread), "running": chats(running), "agentsWorking": agentsWorking,
            "agentsNeedingInput": agentsNeedingInput, "updateReady": updateReady, "showsGlobalKey": showsGlobalKey,
        ]
        if let signInBackend { out["signInBackend"] = signInBackend }
        if let account {
            out["account"] = object(["lines": account.lines, "team": account.team, "teamSymbol": account.teamSymbol])
        }
        if let keepingAwake {
            out["keepingAwake"] = object(["commands": keepingAwake.commands, "setting": keepingAwake.setting])
        }
        if let computerUse {
            out["computerUse"] = object(["sessions": computerUse.sessions.map { session in
                object(["id": session.id, "agent": session.agent, "appName": session.appName, "bundleID": session.bundleID,
                        "acting": session.acting, "stopped": session.stopped])
            }, "floatingPreview": computerUse.floatingPreview])
        }
        return out
    }
}
