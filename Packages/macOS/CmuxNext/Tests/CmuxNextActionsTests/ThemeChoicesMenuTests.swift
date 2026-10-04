import AppKit
import Testing
@testable import CmuxNextActions

/// Set Room / Workspace / Terminal Theme as a context submenu: one item per
/// theme, the current one checked, hover previews, closing reverts, and a
/// click runs the action with the theme and the right-clicked target.
@MainActor @Suite struct ThemeChoicesMenuTests {
    private func themeItem(_ menu: NSMenu, _ registry: ActionRegistry, _ id: ActionID) throws -> NSMenuItem {
        let title = try #require(registry.title(for: id))
        let plain = title.hasSuffix("…") ? String(title.dropLast()) : title
        // The theme submenu may sit inside the Appearance folder.
        func find(_ menu: NSMenu) -> NSMenuItem? {
            menu.items.first { $0.title == plain } ?? menu.items.lazy.compactMap { $0.submenu.flatMap(find) }.first
        }
        return try #require(find(menu))
    }

    @Test func roomMenuListsEveryThemeAndChecksTheCurrentOne() throws {
        let registry = ActionRegistry.standard()
        registry.bind("space.setTheme") { _ in }
        registry.choiceState = { id, _ in id == "space.setTheme" ? "Nord" : nil }
        let menu = registry.makeContextMenu(for: .profile, target: ActionTargetRef(kind: .profile, id: "default"))
        let submenu = try #require(try themeItem(menu, registry, "space.setTheme").submenu)
        // Ghostty config, onboarding's themes, then More… (the full list).
        #expect(submenu.items.count == 1 + ActionArgument.curatedThemes.count + 2)
        #expect(submenu.items.map(\.title).dropFirst().prefix(ActionArgument.curatedThemes.count).elementsEqual(ActionArgument.curatedThemes))
        #expect(submenu.items.filter { $0.state == .on }.map(\.title) == ["Nord"])
        #expect(submenu.items[submenu.items.count - 2].isSeparatorItem)
    }

    @Test func hoverPreviewsCloseRevertsClickCommits() throws {
        let registry = ActionRegistry.standard()
        var ran: [ActionInvocation] = []
        registry.bind("workspace.setTheme", invoke: { ran.append($0) })
        var previews: [String?] = []
        registry.choicePreview = { id, argument, value, target in
            #expect(id == "workspace.setTheme")
            #expect(argument == "theme")
            #expect(target?.id == "w1")
            previews.append(value)
        }
        let target = ActionTargetRef(kind: .workspace, id: "w1")
        let menu = registry.makeContextMenu(for: .workspaceRow, target: target)
        let submenu = try #require(try themeItem(menu, registry, "workspace.setTheme").submenu)
        let vesper = try #require(submenu.items.first { $0.title == "Vesper" })
        submenu.delegate?.menu?(submenu, willHighlight: vesper)
        submenu.delegate?.menu?(submenu, willHighlight: submenu.items[0])
        submenu.delegate?.menuDidClose?(submenu)
        #expect(previews == ["Vesper", ActionArgument.themeConfigValue, nil])

        _ = (vesper.target as? NSObject)?.perform(vesper.action, with: vesper)
        #expect(ran.first?.target == target)
        #expect(ran.first?["theme"]?.stringValue == "Vesper")
    }

    /// Any text reaches the handler (it validates against every Ghostty
    /// theme); the palette and menus offer the known ones.
    @Test func themeArgumentTakesAnyTextWithSuggestions() throws {
        let descriptor = try #require(ActionRegistry.standard().descriptor(for: "terminal.setTheme"))
        let argument = try #require(descriptor.arguments.first)
        #expect(argument.parse("Gruvbox Dark") == .string("Gruvbox Dark"))
        #expect(argument.parse("light:Rose Pine Dawn,dark:Rose Pine") == .string("light:Rose Pine Dawn,dark:Rose Pine"))
        #expect(argument.suggestions?.source == ActionSuggestions.ghosttyThemes)
        #expect(argument.suggestions?.pinned.first?.value == ActionArgument.themeConfigValue)
    }

    @Test func moreOpensTheFullListWithTheTarget() throws {
        let registry = ActionRegistry.standard()
        registry.bind("terminal.setTheme") { _ in }
        var collected: [(ActionID, ActionInvocation)] = []
        registry.argumentCollector = { collected.append(($0, $1)) }
        let target = ActionTargetRef(kind: .tab, id: "tab_1")
        let menu = registry.makeContextMenu(for: .tab, target: target)
        let submenu = try #require(try themeItem(menu, registry, "terminal.setTheme").submenu)
        let more = try #require(submenu.items.last)
        _ = (more.target as? NSObject)?.perform(more.action, with: more)
        #expect(collected.first?.0 == "terminal.setTheme")
        #expect(collected.first?.1.target == target)
    }
}
