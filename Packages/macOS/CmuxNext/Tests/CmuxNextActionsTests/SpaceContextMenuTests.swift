import AppKit
import Testing
@testable import CmuxNextActions

/// SIDEBAR-FOOTER-AND-SPACE-MENU F3 (Lawrence 2026-10-06): a right-click on a
/// space shows a short Arc-style menu. Change Space Icon…, Remove Space Icon
/// (while the space has an icon, cx-k9go), Rename Space…,
/// Edit Theme Color ›, Set Browser Profile ›, then New Group, then Delete
/// Space…. Every row runs its catalog action (the palette and CLI path) with
/// the right-clicked space as its target. Share, Export and Manage Spaces do
/// not exist yet, so the menu leaves them out.
@MainActor @Suite struct SpaceContextMenuTests {
    static let space = ActionTargetRef(kind: .profile, id: "p1")
    static let profiles = [ActionEnumCase(value: "default", title: "Personal"), ActionEnumCase(value: "work", title: "Work")]

    /// A registry with every space-menu action bound to a recorder. A row
    /// that still needs an argument (an icon) or a confirmation (Delete)
    /// reaches the collector or the presenter, which record the run too.
    private func registry(_ ran: @escaping (ActionID, ActionInvocation) -> Void) -> ActionRegistry {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        registry.argumentCollector = { ran($0, $1) }
        registry.confirmationPresenter = { id, invocation, _ in ran(id, invocation) }
        for id in ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: .profile)) {
            registry.bind(id, invoke: { ran(id, $0) })
        }
        registry.targetChoices = { _, kind, _ in
            kind == .browserProfile ? ActionTargetChoices(cases: Self.profiles, current: "work") : nil
        }
        return registry
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    private func click(_ item: NSMenuItem) {
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
    }

    @Test func theSpaceMenuIsTheArcList() {
        let menu = registry { _, _ in }.makeContextMenu(for: .profile, target: Self.space)
        #expect(titles(menu) == [
            "Change Space Icon…", "Remove Space Icon", "Rename Space…", "Edit Theme Color", "Set Browser Profile", "—",
            "New Group", "—",
            "Delete Space…",
        ])
    }

    /// Each top-level row runs its own shared action on the clicked space.
    @Test func everyRowRunsItsActionOnTheClickedSpace() throws {
        var ran: [(ActionID, ActionInvocation)] = []
        // `ActionMenuTarget` holds the registry weakly, as the app's long-lived
        // registry is the owner; the test keeps it alive past every click.
        let owner = registry { ran.append(($0, $1)) }
        defer { withExtendedLifetime(owner) {} }
        let menu = owner.makeContextMenu(for: .profile, target: Self.space)
        for item in menu.items where !item.isSeparatorItem && item.submenu == nil { click(item) }
        #expect(ran.map(\.0) == ["space.setIcon", "space.clearIcon", "space.rename", "space.newGroup", "space.delete"])
        #expect(ran.allSatisfy { $0.1.target == Self.space })
    }

    /// Set Browser Profile lists every browser profile, checks the space's
    /// current one, and a click sets it for the clicked space.
    @Test func setBrowserProfileListsTheProfiles() throws {
        var ran: [(ActionID, ActionInvocation)] = []
        // `ActionMenuTarget` holds the registry weakly, as the app's long-lived
        // registry is the owner; the test keeps it alive past every click.
        let owner = registry { ran.append(($0, $1)) }
        defer { withExtendedLifetime(owner) {} }
        let menu = owner.makeContextMenu(for: .profile, target: Self.space)
        let submenu = try #require(menu.items.first { $0.title == "Set Browser Profile" }?.submenu)
        #expect(submenu.items.map(\.title) == ["Personal", "Work"])
        #expect(submenu.items.filter { $0.state == .on }.map(\.title) == ["Work"])
        click(submenu.items[0])
        #expect(ran.map(\.0) == ["browserProfile.setSpaceDefault"])
        #expect(ran.first?.1.target == Self.space)
        #expect(ran.first?.1["browserProfile"]?.stringValue == "default")
    }

    /// Edit Theme Color holds the space colors and the Ghostty theme.
    @Test func editThemeColorHoldsColorsAndTheTheme() throws {
        var ran: [(ActionID, ActionInvocation)] = []
        // `ActionMenuTarget` holds the registry weakly, as the app's long-lived
        // registry is the owner; the test keeps it alive past every click.
        let owner = registry { ran.append(($0, $1)) }
        defer { withExtendedLifetime(owner) {} }
        let menu = owner.makeContextMenu(for: .profile, target: Self.space)
        let submenu = try #require(menu.items.first { $0.title == "Edit Theme Color" }?.submenu)
        let green = try #require(submenu.items.first { $0.title == "Space Color: Green" })
        click(green)
        #expect(ran.map(\.0) == ["space.color.green"])
        #expect(ran.first?.1.target == Self.space)
        #expect(submenu.items.contains { $0.submenu != nil && $0.title == "Set Space Theme" })
    }

    /// Change Space Icon… runs `space.setIcon` itself with no icon, so its
    /// handler opens the shared icon picker; the palette's text prompt (the
    /// argument collector) never runs.
    @Test func changeSpaceIconReachesTheHandlerWithNoIcon() throws {
        var handled: [ActionInvocation] = [], collected: [ActionID] = []
        let owner = registry { _, _ in }
        defer { withExtendedLifetime(owner) {} }
        owner.argumentCollector = { id, _ in collected.append(id) }
        owner.bind("space.setIcon", invoke: { handled.append($0) })
        let menu = owner.makeContextMenu(for: .profile, target: Self.space)
        click(try #require(menu.items.first { $0.title == "Change Space Icon…" }))
        #expect(collected.isEmpty, "no text prompt: \(collected)")
        #expect(handled.count == 1)
        #expect(handled.first?.target == Self.space)
        #expect(handled.first?["icon"] == nil)
    }

    /// No profiles known (no browser): the submenu is left out, not empty.
    @Test func noBrowserProfilesLeavesTheRowOut() {
        let registry = registry { _, _ in }
        registry.targetChoices = nil
        let menu = registry.makeContextMenu(for: .profile, target: Self.space)
        #expect(!titles(menu).contains("Set Browser Profile"))
    }
}
