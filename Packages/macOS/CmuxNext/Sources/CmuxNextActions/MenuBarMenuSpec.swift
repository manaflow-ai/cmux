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
    /// between two sections.
    ///
    /// - Parameters:
    ///   - state: What the menu shows besides its fixed rows.
    ///   - isBound: Whether the build binds an action (`ActionRegistry.action(for:)`).
    /// - Returns: The rows, never starting or ending with a separator.
    public func items(for state: MenuBarMenuState, isBound: (ActionID) -> Bool) -> [Item] {
        var out: [Item] = []
        for section in sections(for: state) {
            let rows = Self.bound(section, isBound: isBound)
            guard rows.contains(where: { if case .header = $0 { false } else { true } }) else { continue }
            if !out.isEmpty { out.append(.separator) }
            out += rows
        }
        return out
    }

    /// `rows` without unbound actions, in submenus too, and without a separator left at an end
    /// or next to another.
    private static func bound(_ rows: [Item], isBound: (ActionID) -> Bool) -> [Item] {
        var out: [Item] = []
        for row in rows {
            switch row {
            case .action(let id, _, _) where !isBound(id): continue
            case .sessionAction(let id, _, _, _) where !isBound(id): continue
            case .setting where !isBound("openSettings"): continue
            case .computerUse(let app, let bundleID, let items):
                out.append(.computerUse(app: app, bundleID: bundleID, items: bound(items, isBound: isBound)))
            case .separator where out.last == nil || out.last == .separator: continue
            default: out.append(row)
            }
        }
        if out.last == .separator { out.removeLast() }
        return out
    }

    private func sections(for state: MenuBarMenuState) -> [[Item]] {
        let computerUse: [Item] = state.computerUse.map { [Self.computerUse($0)] } ?? []
        let unread = Self.chats(state.unread, header: Self.text("menu.menuBar.unread", "Unread"))
        let running = Self.chats(state.running, header: Self.text("menu.menuBar.running", "Running"))
        var account: [Item] = []
        if let signedIn = state.account {
            for (index, line) in signedIn.lines.enumerated() {
                account.append(.info(line, symbol: nil, avatar: index == 0))
            }
            if let team = signedIn.team { account.append(.action("openTeamPicker", title: team, symbol: "person.2")) }
        } else {
            account.append(.action("palette.auth.signIn", title: Self.text("menu.menuBar.signIn", "Sign In to cmux…"),
                                   symbol: "person.crop.circle"))
        }
        var agents: [Item] = []
        if let awake = state.keepingAwake {
            // A click opens the setting behind the hold (user 2026-11-09, on the defaults: "nor sure").
            let title = Self.text("menu.menuBar.keepingAwake", "Keeping Mac awake")
            agents.append(awake.setting.map { .setting(title, key: $0, symbol: "cup.and.saucer") }
                ?? .info(title, symbol: "cup.and.saucer", avatar: false))
            if awake.commands > 0 { agents.append(.info(Self.commandsRunning(awake.commands), symbol: "terminal", avatar: false)) }
        }
        if state.agentsWorking > 0 {
            agents.append(.info(Self.agentsWorking(state.agentsWorking), symbol: "circle.dotted", avatar: false))
        }
        if state.agentsNeedingInput > 0 {
            agents.append(.action("agent.jumpToNextNeedingInput", title: Self.needsInput(state.agentsNeedingInput), symbol: "exclamationmark.bubble"))
        }
        let open: [Item] = [
            .action("showMainWindow", title: Self.text("menu.menuBar.openCmux", "Open cmux"), symbol: "macwindow"),
            .action("newTab", title: nil, symbol: "plus.rectangle.on.rectangle"),
            .action("home.show", title: nil, symbol: "house"),
            .action("home.messageChiefPet", title: nil, symbol: "bubble.left"),
            .action("palette.quickAgentChat", title: nil, symbol: "bubble.left.and.text.bubble.right"),
        ]
        let help: [Item] = [
            .action("sendFeedback", title: nil, symbol: "envelope"),
            .action("help.documentation", title: nil, symbol: "book"),
            .action("help.troubleshooting", title: nil, symbol: "lifepreserver"),
        ]
        let community: [Item] = [
            .action("help.discord", title: nil, symbol: "bubble.left.and.bubble.right"),
            .action("help.followOnX", title: nil, symbol: "at"),
            .action("help.github", title: nil, symbol: "chevron.left.forwardslash.chevron.right"),
            .action("updates.whatsNew", title: nil, symbol: "sparkles"),
        ]
        // Restart to Update only on a click (the nightly restart policy): the row runs the same
        // install path as the Update Ready card's button.
        let update: Item = state.updateReady
            ? .action("palette.applyUpdateIfAvailable", title: Self.text("menu.menuBar.restartToUpdate", "Restart to Update"),
                      symbol: "arrow.down.circle.fill")
            : .action("palette.checkForUpdates", title: nil, symbol: "arrow.down.circle")
        let app: [Item] = [.action("about", title: nil, symbol: "info.circle"), update, .action("openSettings", title: nil, symbol: "gear")]
        let logs: [Item] = [
            .action("help.revealLogs", title: nil, symbol: "folder"),
            .action("help.copyLogs", title: nil, symbol: "doc.on.clipboard"),
        ]
        var end: [Item] = []
        if state.account != nil { end.append(.action("palette.auth.signOut", title: nil, symbol: "rectangle.portrait.and.arrow.right")) }
        end.append(.action("quit", title: nil, symbol: "power"))
        return [computerUse, unread, running, account, agents, open, help, community, app, logs, end]
    }

    /// A chat list under its header, ending with More… (Search Everything) past the cap; empty for none.
    private static func chats(_ chats: MenuBarMenuState.Chats, header: String) -> [Item] {
        guard !chats.shown.isEmpty else { return [] }
        var rows: [Item] = [.header(header)] + chats.shown.map(Item.chat)
        if chats.more > 0 { rows.append(.action("search.chats", title: text("menu.menuBar.more", "More…"), symbol: "ellipsis")) }
        return rows
    }

    /// The Computer Use row and its submenu (user 2026-11-09: "make a menu bar that lets you: stop on
    /// agent's CU (must communicate to agent if stopped), focus on an agents cursor for CU"): per
    /// agent session, its line (who, on which app; acting now, idle or stopped), then Stop (or
    /// Resume once stopped), Show Cursor and Show Window; then Focus Calling Terminal, Stop for every
    /// agent, and Agent Activity. With no session: Agent Activity and setup. There is no Take Over:
    /// the person takes over by using the mouse or keyboard (`computerUse.pauseOnTakeover`).
    private static func computerUse(_ state: MenuBarMenuState.ComputerUse) -> Item {
        guard let newest = state.session else {
            return .computerUse(app: nil, bundleID: nil, items: [
                .action("agentActivity.open", title: nil, symbol: "cursorarrow.click.2"),
                .action("palette.computerUse.setup", title: nil, symbol: "gear"),
            ])
        }
        var items: [Item] = []
        for session in state.sessions.prefix(computerUseSessionLimit) {
            items += sessionRows(session)
            items.append(.separator)
        }
        items += [
            .action("computerUseFocusCallingTerminal", title: nil, symbol: "terminal"),
            .action("computerUseStop", title: text("menu.menuBar.computerUse.stopAll", "Stop All Agents"), symbol: "stop.circle"),
            .separator,
            .action("agentActivity.open", title: nil, symbol: "cursorarrow.click.2"),
        ]
        return .computerUse(app: newest.appName, bundleID: newest.bundleID, items: items)
    }

    /// One session's line and its rows: Stop or Resume, Show Cursor, Show Window.
    private static func sessionRows(_ session: MenuBarMenuState.ComputerUse.Session) -> [Item] {
        let line = sessionLine(session)
        let symbol = session.stopped ? "stop.circle" : session.acting ? "cursorarrow.motionlines" : "cursorarrow"
        let title = session.stopped
            ? String(localized: "menu.menuBar.computerUse.stoppedLine", defaultValue: "\(line) (Stopped)", table: "ProfileActions", bundle: .module)
            : line
        let stopOrResume: Item = session.stopped
            ? .command(.computerUseResume(session.id), title: text("menu.menuBar.computerUse.resume", "Resume"), symbol: "play.circle")
            : .sessionAction("computerUseStop", session: session.id, title: text("menu.menuBar.computerUse.stop", "Stop"), symbol: "stop.circle")
        return [
            .info(title, symbol: symbol, avatar: false),
            stopOrResume,
            .command(.computerUseShowCursor(session.id), title: text("menu.menuBar.computerUse.showCursor", "Show Cursor"), symbol: "scope"),
            .sessionAction("computerUseFocus", session: session.id, title: text("menu.menuBar.computerUse.showWindow", "Show Window"),
                           symbol: "macwindow"),
        ]
    }

    /// "Claude Code in Notes", or the one of them the worker knows.
    static func sessionLine(_ session: MenuBarMenuState.ComputerUse.Session) -> String {
        switch (session.agent, session.appName) {
        case let (agent?, app?):
            String(localized: "menu.menuBar.computerUse.agentInApp", defaultValue: "\(agent) in \(app)", table: "ProfileActions", bundle: .module)
        case let (agent?, nil): agent
        case let (nil, app?): app
        case (nil, nil): text("menu.menuBar.computerUse.anAgent", "An agent")
        }
    }

    static func agentsWorking(_ count: Int) -> String {
        String(localized: "menu.menuBar.agentsWorking", defaultValue: "Agents working: \(count)", table: "ProfileActions", bundle: .module)
    }

    static func commandsRunning(_ count: Int) -> String {
        String(localized: "menu.menuBar.commandsRunning", defaultValue: "Commands running: \(count)", table: "ProfileActions", bundle: .module)
    }

    static func needsInput(_ count: Int) -> String {
        String(localized: "menu.menuBar.needsInput", defaultValue: "Needs input: \(count)", table: "ProfileActions", bundle: .module)
    }

    static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "ProfileActions", bundle: .module)
    }
}
