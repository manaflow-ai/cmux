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
/// ``MenuBarMenuBuilder`` turns them into an `NSMenu`.
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
    }

    /// The most Computer Use sessions the row's submenu names.
    public static let computerUseSessionLimit = 5

    /// The most chats one list shows; the rest are behind More….
    public static let chatLimit = 8

    public init() {}

    /// The rows for `state`, with unbound actions and empty sections left out and one separator
    /// between two sections. The rows are built in Rust (cmux-action-catalog `status_menus`).
    ///
    /// - Parameters:
    ///   - state: What the menu shows besides its fixed rows.
    ///   - isBound: Whether the build binds an action (`ActionRegistry.action(for:)`).
    /// - Returns: The rows, never starting or ending with a separator.
    public func items(for state: MenuBarMenuState, isBound: (ActionID) -> Bool) -> [Item] {
        let bound = Self.actionIDs.filter { isBound(ActionID(rawValue: $0)) }
        let request: [String: Any] = ["op": "menu_bar_items", "state": state.json, "locale": RustCatalogCall.language, "bound": bound]
        let rows = RustCatalogCall.reply(request)?["items"] as? [Any] ?? []
        return rows.compactMap(Item.init(node:))
    }

    /// Every action id the menu can show, which `items(for:isBound:)` asks the build about.
    private static let actionIDs: [String] = RustCatalogCall.reply(["op": "menu_bar_action_ids"])?["ids"] as? [String] ?? []

    static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "ProfileActions", bundle: .localizedModule)
    }
}

nonisolated extension MenuBarMenuSpec.Item {
    /// The row a `menu_bar_items` reply row holds, nil when it is not one.
    init?(node: Any) {
        guard let object = node as? [String: Any], let entry = object.first else { return nil }
        let (tag, body) = (entry.key, entry.value)
        let row = body as? [String: Any] ?? [:]
        let title = row["title"] as? String
        let symbol = row["symbol"] as? String ?? ""
        switch tag {
        case "info":
            self = .info(row["text"] as? String ?? "", symbol: row["symbol"] as? String, avatar: row["avatar"] as? Bool ?? false)
        case "action":
            guard let id = row["id"] as? String else { return nil }
            self = .action(ActionID(rawValue: id), title: title, symbol: symbol)
        case "setting":
            guard let key = row["key"] as? String else { return nil }
            self = .setting(row["text"] as? String ?? "", key: key, symbol: symbol)
        case "separator":
            self = .separator
        case "header":
            self = .header(body as? String ?? "")
        case "chat":
            guard let id = row["id"] as? String else { return nil }
            self = .chat(MenuBarMenuState.Chat(id: id, title: row["title"] as? String ?? "", harness: row["harness"] as? String))
        case "command":
            guard let target = row["target"] as? String else { return nil }
            let command: MenuBarMenuSpec.Command
            switch row["command"] as? String {
            case "openChat": command = .openChat(target)
            case "computerUseResume": command = .computerUseResume(target)
            case "computerUseShowCursor": command = .computerUseShowCursor(target)
            default: return nil
            }
            self = .command(command, title: title ?? "", symbol: symbol)
        case "sessionAction":
            guard let id = row["id"] as? String, let session = row["session"] as? String else { return nil }
            self = .sessionAction(ActionID(rawValue: id), session: session, title: title ?? "", symbol: symbol)
        case "computerUse":
            let items = (row["items"] as? [Any] ?? []).compactMap { MenuBarMenuSpec.Item(node: $0) }
            self = .computerUse(app: row["app"] as? String, bundleID: row["bundleID"] as? String, items: items)
        default:
            return nil
        }
    }
}

nonisolated extension MenuBarMenuState {
    /// The state as the `menu_bar_items` request's `state` (cmux-action-catalog `status_menus`).
    var json: [String: Any] {
        func chats(_ chats: Chats) -> [String: Any] {
            ["shown": chats.shown.map(Self.json(chat:)), "more": chats.more]
        }
        var out: [String: Any] = [
            "unread": chats(unread), "running": chats(running),
            "agentsWorking": agentsWorking, "agentsNeedingInput": agentsNeedingInput, "updateReady": updateReady,
        ]
        if let computerUse {
            out["computerUse"] = ["sessions": computerUse.sessions.map { session -> [String: Any] in
                var row: [String: Any] = ["id": session.id, "acting": session.acting, "stopped": session.stopped]
                row["agent"] = session.agent
                row["appName"] = session.appName
                row["bundleID"] = session.bundleID
                return row
            }]
        }
        if let keepingAwake {
            var awake: [String: Any] = ["commands": keepingAwake.commands]
            awake["setting"] = keepingAwake.setting
            out["keepingAwake"] = awake
        }
        if let account {
            var signedIn: [String: Any] = ["lines": account.lines, "teamSymbol": account.teamSymbol]
            signedIn["team"] = account.team
            out["account"] = signedIn
        }
        return out
    }

    private static func json(chat: Chat) -> [String: Any] {
        var row: [String: Any] = ["id": chat.id, "title": chat.title]
        row["harness"] = chat.harness
        return row
    }
}
