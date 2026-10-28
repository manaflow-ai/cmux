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
        #expect(items[2] == .action("openTeamPicker", title: "Manaflow", icon: nil))
        #expect(Array(ids.suffix(2)) == ["palette.auth.signOut", "quit"])
        #expect(!ids.contains("palette.auth.signIn"))
    }

    /// Agents that work show a line; agents that wait show a row that jumps to them. Neither shows at 0.
    @Test func agentStatus() throws {
        let busy = MenuBarMenuSpec().items(for: MenuBarMenuState(agentsWorking: 3, agentsNeedingInput: 1), isBound: Self.everything)
        let ids = Self.ids(busy)
        let start = try #require(ids.firstIndex(of: "-")) + 1
        #expect(Array(ids[start..<start + 3]) == ["info:Agents working: 3", "jumpToUnread", "-"])
        #expect(busy[start] == .info("Agents working: 3", symbol: nil, avatar: false))
        let jump = busy[start + 1]
        #expect(jump == .action("jumpToUnread", title: "Needs input: 1", icon: nil))

        let idle = Self.ids(MenuBarMenuSpec().items(for: MenuBarMenuState(), isBound: Self.everything))
        #expect(!idle.contains("jumpToUnread"))
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
        #expect(items[index] == .action("palette.applyUpdateIfAvailable", title: "Restart to Update", icon: nil))
    }

    /// Rows whose action the build does not bind are left out; a section left empty leaves no
    /// separator, and none starts or ends the menu.
    @Test func unboundRowsAndEmptySectionsAreLeftOut() {
        let bound: Set<ActionID> = ["showMainWindow", "help.discord", "quit"]
        let ids = Self.ids(MenuBarMenuSpec().items(for: MenuBarMenuState(), isBound: { bound.contains($0) }))
        #expect(ids == ["showMainWindow", "-", "help.discord", "-", "quit"])
    }

    /// Raycast's menu icons (user 2026-10-27, with a screenshot of Raycast's menu): a leading
    /// monochrome icon on feedback (exclamation bubble), the manual (info circle),
    /// troubleshooting (warning triangle), the community links (brand marks) and Settings (gear);
    /// none on the account, opening cmux, About, updates, logs, Sign Out or Quit.
    @Test func iconsFollowRaycast() {
        let state = MenuBarMenuState(account: .init(lines: ["Ada"], team: "Manaflow"), agentsWorking: 1,
                                     agentsNeedingInput: 1)
        var icons: [String: MenuBarMenuIcon?] = [:]
        for item in MenuBarMenuSpec().items(for: state, isBound: Self.everything) {
            if case .action(let id, _, let icon) = item { icons[id.rawValue] = icon }
        }
        #expect(icons == [
            "openTeamPicker": nil, "jumpToUnread": nil,
            "showMainWindow": nil, "newTab": nil, "home.show": nil, "home.messageChiefPet": nil,
            "palette.quickAgentChat": nil,
            "sendFeedback": .symbol("exclamationmark.bubble"),
            "help.documentation": .symbol("info.circle"),
            "help.troubleshooting": .symbol("exclamationmark.triangle"),
            "help.discord": .brand(.discord), "help.followOnX": .brand(.x), "help.github": .brand(.github),
            "updates.whatsNew": .symbol("sparkles"),
            "about": nil, "palette.checkForUpdates": nil, "openSettings": .symbol("gearshape"),
            "help.revealLogs": nil, "help.copyLogs": nil, "palette.auth.signOut": nil, "quit": nil,
        ])
    }

    /// The builder draws every icon as a template (it follows light and dark menus) at one size:
    /// a brand mark has the box of an SF Symbol row, and rows with no icon get no image.
    @Test func builderDrawsTemplateIconsOfOneSize() throws {
        let registry = ActionRegistry.standard()
        let ids: [ActionID] = ["help.documentation", "help.discord", "help.followOnX", "help.github", "openSettings", "about", "quit"]
        for id in ids { registry.bind(id) {} }
        let menu = NSMenu()
        MenuBarMenuBuilder(registry: registry).fill(menu, state: MenuBarMenuState())
        func row(_ id: ActionID) throws -> NSMenuItem {
            try #require(menu.items.first { $0.identifier?.rawValue == "cmux.action.\(id.rawValue)" })
        }
        let manual = try #require(try row("help.documentation").image)
        for id: ActionID in ["help.discord", "help.followOnX", "help.github"] {
            let mark = try #require(try row(id).image, "\(id.rawValue) has a brand mark")
            #expect(mark.isTemplate)
            #expect(mark.size == manual.size)
            #expect(mark.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil, "the mark draws")
        }
        #expect(manual.isTemplate)
        #expect(try row("openSettings").image?.isTemplate == true)
        #expect(try row("about").image == nil)
        #expect(try row("quit").image == nil)
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
        #expect(open.image == nil, "Raycast's Open Raycast has no icon")
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
}
