import AppKit
@testable import CmuxNextActions
import Testing

/// The menu bar menu (user 2026-10-27: "make cmux-next menubar, be inspired by raycast ... we have
/// discord instead of slack, we have @cmux now ... add like sign in too"): its rows, in order, for
/// each state, and the NSMenu the builder makes from them.
@MainActor
struct MenuBarMenuSpecTests {
    private static func ids(_ items: [MenuBarMenuSpec.Item]) -> [String] {
        items.map {
            switch $0 {
            case .separator: "-"
            case .info(let text, _, _): "info:\(text)"
            case .action(let id, _, _): id.rawValue
            case .header(let title): "header:\(title)"
            case .chat(let chat): "chat:\(chat.id)"
            case .command(let command, _, _): "command:\(command)"
            case .computerUse(let app, _, _): "computerUse:\(app ?? "")"
            }
        }
    }

    private static let everything: (ActionID) -> Bool = { _ in true }

    /// Signed out: Sign In first, then Raycast's order with cmux's rows; Discord, X and GitHub
    /// as the community rows (no Slack); Settings near the end and Quit last.
    @Test func signedOutOrder() {
        let ids = Self.ids(MenuBarMenuSpec().items(for: MenuBarMenuState(), isBound: Self.everything))
        #expect(ids == [
            "palette.auth.signIn", "-",
            "showMainWindow", "newTab", "home.show", "home.messageChiefPet", "palette.quickAgentChat", "-",
            "sendFeedback", "help.documentation", "help.troubleshooting", "-",
            "help.discord", "help.followOnX", "help.github", "updates.whatsNew", "-",
            "about", "palette.checkForUpdates", "openSettings", "-",
            "help.revealLogs", "help.copyLogs", "-",
            "quit",
        ])
        #expect(!ids.contains { $0.lowercased().contains("slack") })
    }

    /// Signed in: who it is on top (the first line with the avatar), the team row, Sign Out
    /// above Quit, and no Sign In.
    @Test func signedInShowsWhoAndSignOut() throws {
        let state = MenuBarMenuState(account: .init(lines: ["Ada Lovelace", "ada@example.com"], team: "Manaflow"))
        let items = MenuBarMenuSpec().items(for: state, isBound: Self.everything)
        let ids = Self.ids(items)
        #expect(Array(ids.prefix(4)) == ["info:Ada Lovelace", "info:ada@example.com", "openTeamPicker", "-"])
        #expect(items.first == .info("Ada Lovelace", symbol: nil, avatar: true))
        #expect(items[1] == .info("ada@example.com", symbol: nil, avatar: false))
        #expect(items[2] == .action("openTeamPicker", title: "Manaflow", symbol: "person.2"))
        #expect(Array(ids.suffix(2)) == ["palette.auth.signOut", "quit"])
        #expect(!ids.contains("palette.auth.signIn"))
    }

    /// Agents that work show a line; agents that wait show a row that jumps to them. Neither shows at 0.
    @Test func agentStatus() throws {
        let busy = MenuBarMenuSpec().items(for: MenuBarMenuState(agentsWorking: 3, agentsNeedingInput: 1), isBound: Self.everything)
        let ids = Self.ids(busy)
        let start = try #require(ids.firstIndex(of: "-")) + 1
        #expect(Array(ids[start..<start + 3]) == ["info:Agents working: 3", "agent.jumpToNextNeedingInput", "-"])
        let jump = busy[start + 1]
        #expect(jump == .action("agent.jumpToNextNeedingInput", title: "Needs input: 1", symbol: "exclamationmark.bubble"))

        let idle = Self.ids(MenuBarMenuSpec().items(for: MenuBarMenuState(), isBound: Self.everything))
        #expect(!idle.contains("agent.jumpToNextNeedingInput"))
        #expect(!idle.contains { $0.hasPrefix("info:") })
    }

    /// A downloaded update: Restart to Update (the install path, run only on this click) takes
    /// Check for Updates' place.
    @Test func updateReadyOffersRestart() throws {
        let items = MenuBarMenuSpec().items(for: MenuBarMenuState(updateReady: true), isBound: Self.everything)
        let ids = Self.ids(items)
        #expect(!ids.contains("palette.checkForUpdates"))
        let index = try #require(ids.firstIndex(of: "palette.applyUpdateIfAvailable"))
        #expect(ids[index - 1] == "about")
        #expect(items[index] == .action("palette.applyUpdateIfAvailable", title: "Restart to Update", symbol: "arrow.down.circle.fill"))
    }

    /// Rows whose action the build does not bind are left out; a section left empty leaves no
    /// separator, and none starts or ends the menu.
    @Test func unboundRowsAndEmptySectionsAreLeftOut() {
        let bound: Set<ActionID> = ["showMainWindow", "help.discord", "quit"]
        let ids = Self.ids(MenuBarMenuSpec().items(for: MenuBarMenuState(), isBound: { bound.contains($0) }))
        #expect(ids == ["showMainWindow", "-", "help.discord", "-", "quit"])
    }

    /// The builder: registry rows with their ids, a disabled info line, the global key on Open cmux.
    @Test func builderMakesRegistryRows() throws {
        let registry = ActionRegistry.standard()
        for id: ActionID in ["showMainWindow", "help.discord", "help.followOnX", "openSettings", "quit"] { registry.bind(id) {} }
        let menu = NSMenu()
        MenuBarMenuBuilder(registry: registry).fill(menu, state: MenuBarMenuState(agentsWorking: 2, showsGlobalKey: true))
        let ids = menu.items.map { $0.isSeparatorItem ? "-" : ($0.identifier?.rawValue ?? $0.title) }
        #expect(ids == ["Agents working: 2", "-", "cmux.action.showMainWindow", "-", "cmux.action.help.discord",
                        "cmux.action.help.followOnX", "-", "cmux.action.openSettings", "-", "cmux.action.quit"])
        #expect(menu.items[0].isEnabled == false)
        let open = try #require(menu.items.first { $0.identifier?.rawValue == "cmux.action.showMainWindow" })
        #expect(open.title == "Open cmux")
        #expect(open.keyEquivalent == ".")
        #expect(open.keyEquivalentModifierMask == [.control, .option, .command])
        #expect(open.image != nil)
        let discord = try #require(menu.items.first { $0.identifier?.rawValue == "cmux.action.help.discord" })
        #expect(discord.title == "Join the cmux Discord")
        #expect(ActionRegistry.menuRun(of: discord) == nil, "a plain row runs its id")
        #expect(discord.representedObject as? String == "help.discord")
        let x = try #require(menu.items.first { $0.identifier?.rawValue == "cmux.action.help.followOnX" })
        #expect(x.title == "Follow @cmux on X")
        let settings = try #require(menu.items.first { $0.identifier?.rawValue == "cmux.action.openSettings" })
        #expect(settings.keyEquivalent == ",")

        // Filling again (each open) replaces the rows instead of adding to them.
        MenuBarMenuBuilder(registry: registry).fill(menu, state: MenuBarMenuState())
        #expect(!menu.items.contains { $0.title.hasPrefix("Agents working") })
        #expect(menu.items.filter { $0.identifier?.rawValue == "cmux.action.quit" }.count == 1)
    }

    /// User 2026-11-06 ("for our computer use i imagine w'll also want to maybe have something
    /// similar to this in our top right menu button situation"): Computer Use on top, then the
    /// Unread and Running chats under their headers, each capped with More…, before the account.
    @Test func computerUseThenUnreadThenRunningOnTop() throws {
        let chats = (1...10).map { MenuBarMenuState.Chat(id: "c\($0)", title: "Chat \($0)", harness: "codex") }
        let state = MenuBarMenuState(computerUse: .init(session: .init(id: "s1", appName: "Calculator", bundleID: "com.apple.calculator")),
                                     unread: .init(Array(chats.prefix(2))), running: .init(chats))
        let items = MenuBarMenuSpec().items(for: state, isBound: Self.everything)
        let ids = Self.ids(items)
        #expect(Array(ids.prefix(16)) == [
            "computerUse:Calculator", "-",
            "header:Unread", "chat:c1", "chat:c2", "-",
            "header:Running", "chat:c1", "chat:c2", "chat:c3", "chat:c4", "chat:c5", "chat:c6", "chat:c7", "chat:c8", "search.chats",
        ])
        #expect(ids[16] == "-" && ids[17] == "palette.auth.signIn")
        #expect(items[15] == .action("search.chats", title: "More…", symbol: "ellipsis"))
        guard case .computerUse(_, let bundleID, let sub) = items[0] else { throw CancellationError() }
        #expect(bundleID == "com.apple.calculator")
        #expect(Self.ids(sub) == ["command:takeOver(\"s1\")", "computerUseFocus", "computerUseFocusCallingTerminal",
                                  "computerUseStop", "-", "agentActivity.open"])
        let paused = MenuBarMenuState(computerUse: .init(session: .init(id: "s1", paused: true)))
        guard case .computerUse(let app, _, let pausedSub) = MenuBarMenuSpec().items(for: paused, isBound: Self.everything)[0] else {
            throw CancellationError()
        }
        #expect(app == nil)
        #expect(pausedSub.first == .command(.handBack("s1"), title: "Hand Back", symbol: "arrow.uturn.backward"))
    }

    /// No Computer Use (off or not set up) and no chats: none of the new rows. Computer Use on with
    /// nothing driving: the row opens Agent Activity and setup.
    @Test func newSectionsHideWhenEmpty() throws {
        let ids = Self.ids(MenuBarMenuSpec().items(for: MenuBarMenuState(), isBound: Self.everything))
        #expect(!ids.contains { $0.hasPrefix("header:") || $0.hasPrefix("chat:") || $0.hasPrefix("computerUse:") })
        let idle = MenuBarMenuSpec().items(for: MenuBarMenuState(computerUse: .init()), isBound: Self.everything)
        guard case .computerUse(nil, nil, let sub) = idle[0] else { throw CancellationError() }
        #expect(Self.ids(sub) == ["agentActivity.open", "palette.computerUse.setup"])
        // An unbound submenu row leaves no dangling separator.
        let some = MenuBarMenuState(computerUse: .init(session: .init(id: "s")))
        let bound: Set<ActionID> = ["computerUseStop", "quit"]
        guard case .computerUse(_, _, let trimmed) = MenuBarMenuSpec().items(for: some, isBound: { bound.contains($0) })[0] else {
            throw CancellationError()
        }
        #expect(Self.ids(trimmed) == ["command:takeOver(\"s\")", "computerUseStop"])
    }

    /// The builder: native section headers, chat rows that run their command with the harness
    /// mark, and the Computer Use row with the driven app as its badge and a submenu.
    @Test func builderMakesChatAndComputerUseRows() throws {
        let registry = ActionRegistry.standard()
        for id: ActionID in ["computerUseStop", "quit"] { registry.bind(id) {} }
        var ran: [MenuBarMenuSpec.Command] = []
        let target = MenuBarCommandTarget { ran.append($0) }
        let mark = NSImage(size: NSSize(width: 14, height: 14))
        let menu = NSMenu()
        let state = MenuBarMenuState(computerUse: .init(session: .init(id: "s1", appName: "Notes")),
                                     unread: .init([.init(id: "a", title: "Fix the sidebar", harness: "claude-code")]))
        MenuBarMenuBuilder(registry: registry).fill(menu, state: state, commands: target, chatImage: { _ in mark })
        #expect(menu.items[0].title == "Computer Use")
        #expect(menu.items[0].badge?.stringValue == "Notes")
        let sub = try #require(menu.items[0].submenu)
        #expect(sub.items.map(\.title) == ["Take Over", "Stop Computer Use"])
        #expect(menu.items[2].isSectionHeader && menu.items[2].title == "Unread")
        let chat = menu.items[3]
        #expect(chat.title == "Fix the sidebar" && chat.image === mark)
        _ = chat.target?.perform(chat.action, with: chat)
        _ = sub.items[0].target?.perform(sub.items[0].action, with: sub.items[0])
        #expect(ran == [.openChat("a"), .takeOver("s1")])

        // The host's answer after opening rewrites the row in place: paused shows Hand Back.
        MenuBarMenuBuilder(registry: registry).updateComputerUse(in: menu, .init(session: .init(id: "s1", paused: true)), commands: target)
        #expect(menu.items[0].badge == nil)
        #expect(menu.items[0].submenu?.items.first?.title == "Hand Back")
        #expect(menu.items[2].title == "Unread", "no other row moves")
    }
}
