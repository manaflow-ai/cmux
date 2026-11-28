import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-11-08: "the sidebar where when things maybe open or shift a bit, there's like still a bit of a flicker on
/// that, like individual top group". What one fold redraws, counted in the turn it runs: a top section of the sidebar
/// document (a block in the list) folded and opened, and a workspace group folded and opened. Each phase prints its
/// counts ("fold-work"): list reloads, rows configured, row views made or swapped, the block's item views before and
/// after, and the block's frame against its content right after the fold (an item view gone while its slot still shows
/// is a frame with rows absent). Every phase runs in one main-actor turn, so no other suite's sidebar counts in it.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarFoldWorkCountTests {
    static let pinnedItems = (0..<6).map { LayoutItemID("itm_fold_\($0)") }
    static let rows = (0..<40).map { WorkspaceID("fold-ws-\($0)") }
    static let group = GroupID("fold-g")
    static let blockKey = SidebarRowKey.block(SidebarLayoutDocument.pinnedSectionID.rawValue)

    final class Harness {
        let model: SidebarModel
        let sidebar: SidebarView
        let window: NSWindow
        var list: SidebarListView { sidebar.list }
        var block: SidebarBlockRowView? { list.rowViews[SidebarFoldWorkCountTests.blockKey] as? SidebarBlockRowView }

        init() {
            _ = NSApplication.shared
            let pinned = LayoutSection(id: SidebarLayoutDocument.pinnedSectionID, title: "Pinned", region: .top, look: .builtIn, arrangement: .list,
                                       items: SidebarFoldWorkCountTests.pinnedItems.map { LayoutItem(id: $0, ref: .workspace("s:\($0.rawValue)")) })
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let ws = { (id: WorkspaceID) in SidebarWorkspace(id: id, title: id.rawValue) }
            let members = SidebarFoldWorkCountTests.rows.prefix(5).map(ws)
            let nodes: [SidebarNode] = [.group(SidebarGroup(id: SidebarFoldWorkCountTests.group, name: "Group", color: .green, workspaces: Array(members)))]
                + SidebarFoldWorkCountTests.rows.dropFirst(5).map { .workspace(ws($0)) }
            let blockSection = SidebarSection(kind: .custom(SidebarCustomSection(id: SidebarLayoutDocument.pinnedSectionID.rawValue)), nodes: [])
            model = SidebarModel(sections: [blockSection, SidebarSection(kind: .machine(machine), nodes: nodes)])
            model.docDrag = SidebarDocDrag(item: { _ in nil }, section: { _ in nil }, begin: { _ in [:] }, drop: { _, _ in }, adoptRef: { _ in nil })
            model.layout = SidebarLayoutDocument(sections: [pinned])
            model.itemInfo = Dictionary(uniqueKeysWithValues: SidebarFoldWorkCountTests.pinnedItems.map { id in
                var info = SidebarItemInfo(title: id.rawValue, symbol: "terminal")
                info.workspace = WorkspaceID("ws-\(id.rawValue)")
                return (id, info)
            })
            sidebar = SidebarView(model: model, design: DesignSettings())
            sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
            window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = sidebar
            window.orderFrontRegardless()
            sidebar.renderNow()
            settle()
            list.reload(animated: false)
            settle()
        }

        func settle() {
            sidebar.bandsDirty = true
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
            list.fitToClip()
            sidebar.layoutSubtreeIfNeeded()
        }
    }

    /// One phase's work.
    struct Work: CustomStringConvertible {
        var reloads = 0, folds = 0, rowConfigures = 0, rowViewsMade = 0, itemsRemoved = 0, itemsAdded = 0, itemsConfigured = 0
        /// Rows `SidebarLayout.make` laid out (every listed row per full layout).
        var layoutRows = 0
        /// Realized rows before the phase whose key now has another view (removed and re-added).
        var swapped = 0
        /// Realized rows before and after.
        var realizedBefore = 0, realizedAfter = 0
        /// The block's item views before and right after, and its row's height against its content right after.
        var blockItemsBefore = 0, blockItemsAfter = 0
        var blockFrameHeight: CGFloat = 0, blockContentHeight: CGFloat = 0
        var description: String {
            "(reloads: \(reloads), layoutRows: \(layoutRows), groupFolds: \(folds), rowConfigures: \(rowConfigures)/\(realizedBefore) realized, rowViewsMade: \(rowViewsMade), "
                + "swapped: \(swapped), realizedAfter: \(realizedAfter), itemsRemoved: \(itemsRemoved), itemsAdded: \(itemsAdded), itemsConfigured: \(itemsConfigured), "
                + "blockItems: \(blockItemsBefore)->\(blockItemsAfter), blockFrame: \(blockFrameHeight) content: \(blockContentHeight))"
        }
    }

    static func measure(_ h: Harness, _ body: () -> Void) -> Work {
        var work = Work()
        let before = h.list.rowViews.mapValues { ObjectIdentifier($0) }
        work.realizedBefore = before.count
        let items = Set((h.block?.region.itemViews.values).map { $0.map { ObjectIdentifier($0) } } ?? [])
        work.blockItemsBefore = items.count
        _ = h.block?.region.listWork.take()
        _ = SidebarPerfCounters.report(reset: true)
        h.model.noteUserIntent()
        body()
        h.sidebar.bandsDirty = true
        h.sidebar.needsLayout = true
        h.sidebar.layoutSubtreeIfNeeded()
        let r = SidebarPerfCounters.report(reset: true)
        (work.reloads, work.folds, work.rowConfigures) = (r["list_reloads"] ?? 0, r["group_folds"] ?? 0, r["row_configures"] ?? 0)
        work.layoutRows = r["layout_rows"] ?? 0
        work.rowViewsMade = r["row_views_made"] ?? 0
        let after = Set((h.block?.region.itemViews.values).map { $0.map { ObjectIdentifier($0) } } ?? [])
        (work.itemsRemoved, work.itemsAdded) = (items.subtracting(after).count, after.subtracting(items).count)
        work.itemsConfigured = h.block?.region.listWork.take().rowsConfigured ?? 0
        work.swapped = before.filter { key, id in h.list.rowViews[key].map { ObjectIdentifier($0) != id } ?? false }.count
        work.realizedAfter = h.list.rowViews.count
        work.blockItemsAfter = h.block?.region.itemViews.count ?? 0
        work.blockFrameHeight = h.block?.frame.height ?? 0
        work.blockContentHeight = h.block?.region.layoutResult.height ?? 0
        return work
    }

    @Test func whatOneFoldRedraws() throws {
        let h = Harness()
        defer { h.window.closeAfterTest() }
        try #require(h.block != nil, "the list draws no Pinned block")
        let pinned = SidebarLayoutDocument.pinnedSectionID
        let closeTop = Self.measure(h) { h.model.send(.toggleLayoutSection(pinned)) }
        let openTop = Self.measure(h) { h.model.send(.toggleLayoutSection(pinned)) }
        let closeGroup = Self.measure(h) { h.model.send(.toggleCollapse(.group(Self.group))) }
        let openGroup = Self.measure(h) { h.model.send(.toggleCollapse(.group(Self.group))) }
        print("fold-work top-section close=\(closeTop)")
        print("fold-work top-section open=\(openTop)")
        print("fold-work group close=\(closeGroup)")
        print("fold-work group open=\(openGroup)")
        #expect(closeTop.realizedBefore > 0 && closeGroup.realizedBefore > 0)
    }
}
