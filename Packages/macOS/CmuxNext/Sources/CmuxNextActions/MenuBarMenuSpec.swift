/// The menu bar menu, top to bottom (user 2026-10-27, after Raycast's menu): the account, the agents
/// that work or wait, opening cmux, help, cmux's community, the app, logs, then Sign Out and Quit.
///
/// Every row runs a registry action, so the palette, the Help menu and this menu share one path.
/// A row whose action the build does not bind is left out, and so is a section left with no row.
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
        /// A divider between two sections.
        case separator
    }

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
            let rows = section.filter {
                guard case .action(let id, _, _) = $0 else { return true }
                return isBound(id)
            }
            guard !rows.isEmpty else { continue }
            if !out.isEmpty { out.append(.separator) }
            out += rows
        }
        return out
    }

    private func sections(for state: MenuBarMenuState) -> [[Item]] {
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
            .action("help.setupGuide", title: nil, symbol: "book"),
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
        return [account, agents, open, help, community, app, logs, end]
    }

    static func agentsWorking(_ count: Int) -> String {
        String(localized: "menu.menuBar.agentsWorking", defaultValue: "Agents working: \(count)", table: "ProfileActions", bundle: .module)
    }

    static func needsInput(_ count: Int) -> String {
        String(localized: "menu.menuBar.needsInput", defaultValue: "Needs input: \(count)", table: "ProfileActions", bundle: .module)
    }

    static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "ProfileActions", bundle: .module)
    }
}
