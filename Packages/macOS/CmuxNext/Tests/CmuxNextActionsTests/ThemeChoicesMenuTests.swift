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
        return try #require(menu.items.first { $0.title == plain })
    }

    @Test func roomMenuListsEveryThemeAndChecksTheCurrentOne() throws {
        let registry = ActionRegistry.standard()
        registry.bind("room.setTheme") { _ in }
        registry.choiceState = { id, _ in id == "room.setTheme" ? "Nord" : nil }
        let menu = registry.makeContextMenu(for: .profile, target: ActionTargetRef(kind: .profile, id: "default"))
        let submenu = try #require(try themeItem(menu, registry, "room.setTheme").submenu)
        #expect(submenu.items.count == 1 + ActionArgument.curatedThemes.count)
        #expect(submenu.items.map(\.title).dropFirst().elementsEqual(ActionArgument.curatedThemes))
        #expect(submenu.items.filter { $0.state == .on }.map(\.title) == ["Nord"])
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

    @Test func themeArgumentAcceptsOnlyListedThemes() throws {
        let descriptor = try #require(ActionRegistry.standard().descriptor(for: "terminal.setTheme"))
        let argument = try #require(descriptor.arguments.first)
        #expect(argument.parse("Gruvbox Dark") == .string("Gruvbox Dark"))
        #expect(argument.parse("config") == .string("config"))
        #expect(argument.parse("theme = evil") == nil)
    }
}
