import AppKit
@testable import CmuxNextActions
import Testing

/// `contributes.menus`: the rows apps add to a whole right-click menu go after its built-in rows,
/// as one group before Customize Menu…, and only into a whole menu on a target.
@MainActor
struct ContributedMenuItemsTests {
    private func registry() -> ActionRegistry {
        let registry = ActionRegistry.standard()
        registry.customizeMenu = { _ in }
        registry.contributedMenuItems = { context, target in
            context == .tab ? [NSMenuItem(title: "Copy Branch \(target.id)", action: nil, keyEquivalent: "")] : []
        }
        return registry
    }

    @Test func aWholeMenuEndsWithTheAppRowsThenCustomize() {
        let menu = registry().makeContextMenu(for: .tab, target: ActionTargetRef(kind: .tab, id: "t1"))
        let titles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        #expect(Array(titles.suffix(4).dropLast()) == ["—", "Copy Branch t1", "—"], "\(titles)")
        #expect(titles.filter { $0 == "Copy Branch t1" }.count == 1)
    }

    @Test func rowsTakenIntoAnotherMenuAndMenusWithoutATargetGetNone() {
        let registry = registry()
        let detached = registry.contextMenuItems(for: .tab, target: ActionTargetRef(kind: .tab, id: "t1"))
        #expect(!detached.contains { $0.title.hasPrefix("Copy Branch") })
        let untargeted = registry.makeContextMenu(for: .tab)
        #expect(!untargeted.items.contains { $0.title.hasPrefix("Copy Branch") })
    }
}
