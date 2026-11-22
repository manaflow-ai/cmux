import AppKit
import Testing
@testable import CmuxNextActions

/// cx-k9go context menu pass (chief decisions 2026-10-08): Close Other Panes
/// in a pane's menu, Copy Workspace Group ID in a group's menu, and Open Link
/// in Default Browser in a link's menu, each running its shared catalog
/// action on the right-clicked object.
@MainActor @Suite struct ContextMenuNicetiesTests {
    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.flatMap { item -> [String] in
            item.isSeparatorItem ? [] : [item.title] + (item.submenu.map(titles) ?? [])
        }
    }

    private func menu(_ context: ActionMenuContext, _ target: ActionTargetRef, arguments: [String: ActionValue] = [:],
                      ran: @escaping (ActionID, ActionInvocation) -> Void = { _, _ in }) -> (ActionRegistry, NSMenu) {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        registry.argumentCollector = { ran($0, $1) }
        for id in ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: context)) {
            registry.bind(id, invoke: { ran(id, $0) })
        }
        return (registry, registry.makeContextMenu(for: context, target: target, arguments: arguments))
    }

    private func item(_ menu: NSMenu, _ title: String) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title { return item }
            if let found = item.submenu.flatMap({ self.item($0, title) }) { return found }
        }
        return nil
    }

    @Test func closeOtherPanesRunsOnTheClickedPane() throws {
        var ran: [(ActionID, ActionInvocation)] = []
        let pane = ActionTargetRef(kind: .pane, id: "p1")
        let (owner, built) = menu(.pane, pane) { ran.append(($0, $1)) }
        defer { withExtendedLifetime(owner) {} }
        let row = try #require(item(built, "Close Other Panes"), "\(titles(built))")
        _ = (row.target as? NSObject)?.perform(row.action, with: row)
        #expect(ran.map(\.0) == ["pane.closeOthers"])
        #expect(ran.first?.1.target == pane)
    }

    @Test func aGroupMenuCopiesTheGroupID() {
        let (owner, built) = menu(.workspaceGroup, ActionTargetRef(kind: .workspaceGroup, id: "g1"))
        defer { withExtendedLifetime(owner) {} }
        #expect(titles(built).contains("Copy Workspace Group ID"))
    }

    @Test func aLinkMenuOpensInTheDefaultBrowser() throws {
        var ran: [(ActionID, ActionInvocation)] = []
        let url: [String: ActionValue] = ["url": .string("https://example.com")]
        let (owner, built) = menu(.browserLink, ActionTargetRef(kind: .tab, id: "t1"), arguments: url) { ran.append(($0, $1)) }
        defer { withExtendedLifetime(owner) {} }
        let row = try #require(item(built, "Open Link in Default Browser"), "\(titles(built))")
        _ = (row.target as? NSObject)?.perform(row.action, with: row)
        #expect(ran.map(\.0) == ["openLinkInDefaultBrowser"])
        #expect(ran.first?.1["url"]?.stringValue == "https://example.com")
    }
}
