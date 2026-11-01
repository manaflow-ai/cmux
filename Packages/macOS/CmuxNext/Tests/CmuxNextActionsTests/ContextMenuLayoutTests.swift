import AppKit
@testable import CmuxNextActions
import Testing

/// Settings > Menus: a person's arrangement of a right-click menu (`ContextMenuLayout`) is the
/// whole menu as a tree, so any row goes anywhere at any depth: out of More or any submenu, into
/// any submenu, a submenu into another, rows reordered inside a submenu, the person's own
/// submenus, rows hidden. The menu the registry builds is that tree; a row the app adds later
/// still shows where the app puts it.
@MainActor
struct ContextMenuLayoutTests {
    typealias Node = ContextMenuLayout.Node

    /// Each top-level row as the action it runs, the folder key for a folder, "—" for a separator.
    private func rows(_ menu: NSMenu) -> [String] {
        menu.items.map { item in
            if item.isSeparatorItem { return "—" }
            if ActionRegistry.isCustomizeItem(item) { return "Customize" }
            if let id = ActionRegistry.menuRun(of: item)?.id { return id.rawValue }
            if let folder = MenuFolder.allCases.first(where: { $0.title == item.title }) { return ContextMenuLayout.folderKey(folder) }
            return item.title
        }
    }

    private func allActions(_ menu: NSMenu) -> [String] {
        menu.items.flatMap { item in
            (ActionRegistry.menuRun(of: item).map { [$0.id.rawValue] } ?? []) + (item.submenu.map(allActions) ?? [])
        }
    }

    /// The submenu of the row titled `title` in `menu`.
    private func submenu(_ title: String, in menu: NSMenu?) -> NSMenu? {
        menu?.items.first { $0.title == title }?.submenu
    }

    private func registry() -> ActionRegistry {
        let registry = ActionRegistry.standard()
        for id: ActionID in ["palette.workspaceColor", "moveWorkspaceToGroup"] { registry.bind(id, invoke: { _ in }) }
        return registry
    }

    private let workspace = ActionTargetRef(kind: .workspace, id: "ws")
    private var generated: [ContextMenuEntry] { ContextMenuCatalog.shared.entries(for: .workspaceRow) }
    private var move: String { ContextMenuLayout.folderKey(.move) }

    /// A row the built menu shows directly in More.
    private var rowInMore: String {
        let more = submenu(MenuFolder.more.title, in: registry().makeContextMenu(for: .workspaceRow, target: workspace))
        return more!.items.compactMap(ActionRegistry.menuRun(of:)).first!.id.rawValue
    }

    /// `tree` with `key` taken out wherever it is.
    private func removing(_ key: String, from tree: [Node]) -> [Node] {
        tree.compactMap { node in
            if node.key == key { return nil }
            if case .folder(let k, let title, let items) = node { return .folder(key: k, title: title, items: removing(key, from: items)) }
            return node
        }
    }

    /// `tree` with `node` put first inside submenu `folder`.
    private func inserting(_ node: Node, into folder: String, in tree: [Node]) -> [Node] {
        tree.map { entry in
            guard case .folder(let k, let title, let items) = entry else { return entry }
            if k == folder { return .folder(key: k, title: title, items: [node] + items) }
            return .folder(key: k, title: title, items: inserting(node, into: folder, in: items))
        }
    }

    private func folder(_ key: String, in nodes: [Node]) -> [Node]? {
        for case .folder(let k, _, let items) in nodes {
            if k == key { return items }
            if let found = folder(key, in: items) { return found }
        }
        return nil
    }

    @Test func noLayoutDrawsTheGeneratedMenu() {
        let plain = registry().makeContextMenu(for: .workspaceRow, target: workspace)
        let arranged = registry()
        arranged.contextMenuLayouts[.workspaceRow] = .generated(generated)
        #expect(rows(arranged.makeContextMenu(for: .workspaceRow, target: workspace)) == rows(plain))
        #expect(ContextMenuLayout.generated(generated).isGenerated(for: generated))
    }

    @Test func aRowOfMoreMovesToTheTopLevelAndATopRowIntoASubmenu() throws {
        let registry = registry()
        let promoted = rowInMore
        var items = removing(promoted, from: ContextMenuLayout.generated(generated).items)
        items.insert(.item(promoted), at: 0)
        // Rename goes into Move ▸, first.
        items = inserting(.item("renameWorkspace"), into: move, in: removing("renameWorkspace", from: items))
        registry.contextMenuLayouts[.workspaceRow] = ContextMenuLayout(items: items, hidden: ["workspace.duplicate"])
        let menu = registry.makeContextMenu(for: .workspaceRow, target: workspace)
        #expect(rows(menu).first == promoted)
        #expect(allActions(menu).filter { $0 == promoted }.count == 1)
        let moveMenu = try #require(submenu(MenuFolder.move.title, in: menu))
        #expect(moveMenu.items.first.flatMap(ActionRegistry.menuRun(of:))?.id == "renameWorkspace")
        #expect(!rows(menu).contains("renameWorkspace"))
        #expect(!allActions(menu).contains("workspace.duplicate"))
    }

    @Test func aSubmenuMovesIntoAnotherWithItsRows() throws {
        // Move ▸ goes inside More ▸, at its top.
        let base = ContextMenuLayout.generated(generated).items
        let moveNode = try #require(base.first { $0.key == move })
        let items = inserting(moveNode, into: ContextMenuLayout.moreKey, in: removing(move, from: base))
        let registry = registry()
        registry.contextMenuLayouts[.workspaceRow] = ContextMenuLayout(items: items)
        let menu = registry.makeContextMenu(for: .workspaceRow, target: workspace)
        #expect(!rows(menu).contains(move))
        let more = try #require(submenu(MenuFolder.more.title, in: menu))
        let nested = try #require(submenu(MenuFolder.move.title, in: more))
        #expect(nested.items.compactMap(ActionRegistry.menuRun(of:)).map(\.id).contains("palette.moveWorkspaceToTop"))
    }

    @Test func thePersonsOwnSubmenuHoldsAnyRowsAtAnyDepth() throws {
        let base = ContextMenuLayout.generated(generated).items
        let inner: Node = .folder(key: "group:inner", title: "Deeper", items: [.item("workspace.duplicate")])
        let mine: Node = .folder(key: "group:mine", title: "Mine", items: [.item("renameWorkspace"), .separator, inner])
        let items = [mine] + removing("workspace.duplicate", from: removing("renameWorkspace", from: base))
        let registry = registry()
        registry.contextMenuLayouts[.workspaceRow] = ContextMenuLayout(items: items)
        let menu = registry.makeContextMenu(for: .workspaceRow, target: workspace)
        #expect(menu.items.first?.title == "Mine")
        let mineMenu = try #require(submenu("Mine", in: menu))
        #expect(rows(mineMenu) == ["renameWorkspace", "—", "Deeper"])
        #expect(rows(try #require(submenu("Deeper", in: mineMenu))) == ["workspace.duplicate"])
        // An empty submenu of the person's shows nowhere.
        registry.contextMenuLayouts[.workspaceRow] = ContextMenuLayout(items: [.folder(key: "group:empty", title: "Empty", items: [])] + base)
        #expect(!registry.makeContextMenu(for: .workspaceRow, target: workspace).items.contains { $0.title == "Empty" })
    }

    @Test func aRowTheAppAddsLaterShowsInItsSubmenuWhereverThatSubmenuWent() throws {
        // Saved before Move to Top existed, with Move ▸ moved into More ▸.
        let base = ContextMenuLayout.generated(generated).items
        let moveRows = try #require(folder(move, in: base))
        let oldMove: Node = .folder(key: move, title: nil, items: moveRows.filter { $0.key != "palette.moveWorkspaceToTop" })
        let saved = ContextMenuLayout(items: inserting(oldMove, into: ContextMenuLayout.moreKey, in: removing(move, from: base)))
        let normalized = saved.normalized(against: generated)
        let moved = folder(ContextMenuLayout.moreKey, in: normalized.items).flatMap { folder(move, in: $0) }
        #expect(moved?.first?.key == "palette.moveWorkspaceToTop", "the new row is first in Move ▸, as the app puts it")
        #expect(!normalized.items.contains { $0.key == move }, "Move ▸ stays inside More ▸")
        // A row the app no longer places, or a submenu it no longer makes, is dropped; a gone
        // submenu's rows stay where it was.
        var stale = ContextMenuLayout.generated(generated)
        stale.items.insert(.folder(key: "folder:gone", title: nil, items: [.item("retired.action")]), at: 0)
        #expect(stale.normalized(against: generated) == .generated(generated))
    }

    @Test func aHiddenSubmenuTakesItsRowsWithIt() {
        let registry = registry()
        var layout = ContextMenuLayout.generated(generated)
        layout.hidden = [move]
        registry.contextMenuLayouts[.workspaceRow] = layout
        let menu = registry.makeContextMenu(for: .workspaceRow, target: workspace)
        #expect(!rows(menu).contains(move))
        #expect(!allActions(menu).contains("palette.moveWorkspaceToTop"))
    }

    @Test func aNewRowStaysInItsGeneratedSection() {
        // Generated [A, -, N, B]; saved before N existed as [A, -, B]: N joins B's section, not A's.
        let generated: [ContextMenuEntry] = [.action("a"), .separator, .action("n"), .action("b")]
        let saved = ContextMenuLayout(items: [.item("a"), .separator, .item("b")])
        #expect(saved.normalized(against: generated).items == [.item("a"), .separator, .item("n"), .item("b")])
    }

    @Test func aSubmenuTheLayoutDoesNotFillGetsItsRowsBackWithTheirDividers() {
        // A hand-written layout naming More with no rows, and an app update that adds a section:
        // the rows come back where the app puts them, with the dividers between their sections.
        let generated: [ContextMenuEntry] = [
            .action("a"), .separator, .action("n1"), .action("n2"),
            .folder(.more, [.action("m1"), .separator, .action("m2"), .action("m3"), .separator, .action("m4")]),
        ]
        let more = ContextMenuLayout.moreKey
        let saved = ContextMenuLayout(items: [.item("a"), .folder(key: more, title: nil, items: [])])
        let normalized = saved.normalized(against: generated)
        #expect(normalized.items == [
            .item("a"), .separator, .item("n1"), .item("n2"),
            .folder(key: more, title: nil, items: [.item("m1"), .separator, .item("m2"), .item("m3"), .separator, .item("m4")]),
        ])
        // A whole submenu the layout does not name at all keeps its dividers too.
        let without = ContextMenuLayout(items: [.item("a"), .separator, .item("n1"), .item("n2")]).normalized(against: generated)
        #expect(without.items.last == .folder(key: more, title: nil, items: [.item("m1"), .separator, .item("m2"), .item("m3"), .separator, .item("m4")]))
        // Rows the person moved into More stay first in it; the app's rows follow, with their dividers.
        let moved = ContextMenuLayout(items: [.item("n1"), .item("n2"), .folder(key: more, title: nil, items: [.item("a"), .separator])])
        guard case .folder(_, _, let rows)? = moved.normalized(against: generated).items.last else { Issue.record("no More"); return }
        #expect(rows == [.item("a"), .separator, .item("m1"), .separator, .item("m2"), .item("m3"), .separator, .item("m4")])
    }

    @Test func aNewRowNeverSplitsASectionThePersonReordered() {
        // A new row at the start of a section the person reordered joins it, no divider inside.
        let first: [ContextMenuEntry] = [.action("a"), .separator, .action("n"), .action("b"), .action("c")]
        #expect(ContextMenuLayout(items: [.item("a"), .separator, .item("c"), .item("b")]).normalized(against: first).items
            == [.item("a"), .separator, .item("c"), .item("n"), .item("b")])
        // A new section after a reordered one goes after that whole run, not inside it.
        let after: [ContextMenuEntry] = [.action("a"), .action("b"), .separator, .action("n")]
        #expect(ContextMenuLayout(items: [.item("b"), .item("a")]).normalized(against: after).items
            == [.item("b"), .item("a"), .separator, .item("n")])
        // A new section before a reordered one goes before that whole run.
        let before: [ContextMenuEntry] = [.action("n"), .separator, .action("a"), .action("b")]
        #expect(ContextMenuLayout(items: [.item("b"), .item("a")]).normalized(against: before).items
            == [.item("n"), .separator, .item("b"), .item("a")])
    }

    @Test func eachRowShowsOnceHoweverOftenItIsNamed() {
        let more = ContextMenuLayout.moreKey
        let generated: [ContextMenuEntry] = [.action("a"), .folder(.more, [.action("b")])]
        let saved = ContextMenuLayout(items: [.item("a"), .item("a"), .folder(key: more, title: nil, items: [.item("a"), .item("b")]),
                                              .folder(key: more, title: nil, items: [.item("b")])])
        #expect(saved.normalized(against: generated).items == [.item("a"), .folder(key: more, title: nil, items: [.item("b")])])
    }

    @Test func wholeMenusEndWithCustomizeMenuWhichOpensThatMenusEditor() throws {
        let registry = registry()
        var opened: [ActionMenuContext] = []
        registry.customizeMenu = { opened.append($0) }
        let menu = registry.makeContextMenu(for: .workspaceRow, target: workspace)
        let item = try #require(menu.items.last)
        #expect(ActionRegistry.isCustomizeItem(item))
        #expect(item.title == "Customize Menu…")
        #expect(menu.items.dropLast().last?.isSeparatorItem == true)
        let target = try #require(item.target as? NSObject)
        target.perform(try #require(item.action), with: item)
        #expect(opened == [.workspaceRow])

        // Rows a caller takes into another menu have none, and the person can turn it off.
        #expect(!registry.makeContextMenu(for: .workspaceRow, entries: [.action("renameWorkspace")]).items.contains(where: ActionRegistry.isCustomizeItem))
        #expect(!registry.makeContextMenu(for: .workspaceRow, target: workspace, customize: false).items.contains(where: ActionRegistry.isCustomizeItem))
        registry.showsCustomizeMenuItem = false
        #expect(!registry.makeContextMenu(for: .workspaceRow, target: workspace).items.contains(where: ActionRegistry.isCustomizeItem))
    }

    @Test func callSiteFiltersApplyAfterTheArrangementAtAnyDepth() {
        let registry = registry()
        let items = [Node.folder(key: "group:mine", title: "Mine", items: [.item("renameWorkspace")])]
            + removing("renameWorkspace", from: ContextMenuLayout.generated(generated).items)
        registry.contextMenuLayouts[.workspaceRow] = ContextMenuLayout(items: items)
        let entries = registry.contextMenuEntries(for: .workspaceRow, removing: ["renameWorkspace"])
        #expect(!ContextMenuCatalog.shared.referencedIDs(entries).contains("renameWorkspace"))
        #expect(!entries.contains { if case .group = $0 { true } else { false } }, "a submenu the filter emptied leaves")
    }

    @Test func aRowMovedIntoMoreIsFoundThere() throws {
        let registry = registry()
        let items = inserting(.item("renameWorkspace"), into: ContextMenuLayout.moreKey,
                              in: removing("renameWorkspace", from: ContextMenuLayout.generated(generated).items))
        registry.contextMenuLayouts[.workspaceRow] = ContextMenuLayout(items: items)
        let menu = registry.makeContextMenu(for: .workspaceRow, target: workspace)
        let found = try #require(ActionRegistry.locate("renameWorkspace", in: menu))
        #expect(found.menu === submenu(MenuFolder.more.title, in: menu))
    }

    @Test func settingsListsEveryMenuOnce() {
        #expect(Set(ActionMenuContext.editorOrder) == Set(ActionMenuContext.allCases))
        #expect(ActionMenuContext.editorOrder.count == ActionMenuContext.allCases.count)
        let menus = registry().contextMenuEditorMenus()
        let workspaceMenu = menus.first { $0.context == .workspaceRow }
        #expect(workspaceMenu?.isCustomized == false)
        #expect(workspaceMenu?.rows.contains { $0.key == "renameWorkspace" && $0.home == nil } == true)
        #expect(workspaceMenu?.rows.contains { $0.key == ContextMenuLayout.moreKey && $0.kind == .folder } == true)
    }
}
