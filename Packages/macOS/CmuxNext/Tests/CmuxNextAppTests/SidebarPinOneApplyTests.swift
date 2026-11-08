import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// A pin or an unpin changes the sidebar document once: the workspace leaves the list's rows and joins the Pinned
/// block (or back) in the same model change (cx-odqn). The sidebar drew the rows at once and the blocks only at its
/// next layout pass, so the list got two updates for one change: the row closed, then (a pass later) the block's item
/// grew in, and an unpin's item could go a pass before its row came. The pin motion (`SidebarListView+PinFlight`)
/// then had to hold views for the second update. Every apply the list makes for the change must draw the workspace
/// exactly once: in the rows or in a block, never in both and never in neither.
@MainActor @Suite(.serialized, .closesItsWindows, .enabled(if: !NSScreen.screens.isEmpty))
struct SidebarPinOneApplyTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let home = LayoutItem(id: LayoutItemID("itm_home"), ref: SidebarLayoutDocument.homeRef)
    static let listed = ["a", "b", "c", "d", "e"].map(WorkspaceID.init)
    static let anchor = WorkspaceID("p")
    static let moved = WorkspaceID("d")

    static func item(_ id: WorkspaceID) -> LayoutItem {
        LayoutItem(id: LayoutItemID("itm_pin_\(id.rawValue)"), ref: .workspace(id.rawValue))
    }

    /// The document with `p` and each of `pins` in Pinned, and the rows it projects (every listed workspace not pinned).
    static func state(_ pins: [WorkspaceID]) -> (layout: SidebarLayoutDocument, sections: [CmuxNextSidebar.SidebarSection]) {
        let pinned = [anchor] + pins
        let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, arrangement: .list, items: [home])
        let section = SidebarLayoutDocument.pinnedSection(items: pinned.map(item))
        let sections = [
            CmuxNextSidebar.SidebarSection(kind: .custom(SidebarCustomSection(id: top.id.rawValue)), nodes: []),
            CmuxNextSidebar.SidebarSection(kind: .custom(SidebarCustomSection(id: section.id.rawValue)), nodes: []),
            CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: listed.filter { !pinned.contains($0) }
                .map { .workspace(SidebarWorkspace(id: $0, title: $0.rawValue)) }),
        ]
        return (SidebarLayoutDocument(sections: [top, section]), sections)
    }

    final class Harness {
        let model: SidebarModel
        let sidebar: SidebarView
        let window: NSWindow
        var list: SidebarListView { sidebar.list }

        init(pins: [WorkspaceID], active: WorkspaceID? = nil) {
            _ = NSApplication.shared
            let (layout, sections) = SidebarPinOneApplyTests.state(pins)
            model = SidebarModel(sections: sections, activeWorkspaceID: active)
            model.docDrag = SidebarDocDrag(item: { _ in nil }, section: { _ in nil }, begin: { _ in [:] }, drop: { _, _ in },
                                           adoptRef: { _ in nil })
            model.layout = layout
            sidebar = SidebarView(model: model, design: DesignSettings.shared)
            sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 560)
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 560), styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(sidebar)
            window.orderFrontRegardless()
            sidebar.list.leftButtonIsDown = { false }
            sidebar.renderNow()
            sidebar.layoutSubtreeIfNeeded()
            list.reload(animated: false)
            sidebar.layoutSubtreeIfNeeded()
        }

        /// Whether the list's blocks draw `id` now.
        func blocksDraw(_ id: WorkspaceID) -> Bool {
            list.blocks?.sections.values.contains { $0.items.contains { $0.ref == .workspace(id.rawValue) } } ?? false
        }
    }

    /// Pins (`pin`) or unpins `d` in one document change and records, for every apply the list makes, whether its rows
    /// and its blocks draw `d`. `layoutFirst`: a layout pass of the sidebar runs before its render (another change
    /// asked for one), as an observation hop can let it.
    func applies(pin: Bool, layoutFirst: Bool) -> (before: (rows: Bool, blocks: Bool), applies: [(rows: Bool, blocks: Bool)]) {
        let h = Harness(pins: pin ? [] : [Self.moved])
        defer { h.window.close() }
        let before = (rows: h.list.displayed.row(for: .workspace(Self.moved)) != nil, blocks: h.blocksDraw(Self.moved))
        var seen: [(rows: Bool, blocks: Bool)] = []
        h.list.onApply = { [unowned h] layout in
            seen.append((rows: layout.row(for: .workspace(Self.moved)) != nil, blocks: h.blocksDraw(Self.moved)))
        }
        let (layout, sections) = Self.state(pin ? [Self.moved] : [])
        // A pin is the user's: its change moves rows (calm-sidebar-movement holds only changes nobody asked for).
        h.model.noteUserIntent()
        h.model.layout = layout
        h.model.sections = sections
        if layoutFirst {
            h.sidebar.bandsDirty = true
            h.sidebar.needsLayout = true
            h.sidebar.layoutSubtreeIfNeeded()
        }
        h.sidebar.renderNow()
        h.sidebar.layoutSubtreeIfNeeded()
        h.list.onApply = nil
        return (before, seen)
    }

    @Test(arguments: [true, false], [false, true])
    func aPinOrAnUnpinReachesTheListInOneApply(pin: Bool, layoutFirst: Bool) {
        let (before, seen) = applies(pin: pin, layoutFirst: layoutFirst)
        let name = "\(pin ? "pin" : "unpin")\(layoutFirst ? " (layout pass first)" : "")"
        #expect(before.rows == pin && before.blocks == !pin, "\(name): the start state draws d in rows \(before.rows), blocks \(before.blocks)")
        #expect(!seen.isEmpty, "\(name): the list never applied the change")
        for (index, apply) in seen.enumerated() {
            #expect(apply.rows != apply.blocks,
                    "\(name): apply \(index) of \(seen.count) draws d in rows \(apply.rows), in blocks \(apply.blocks)")
        }
        if let last = seen.last { #expect(last.rows == !pin && last.blocks == pin, "\(name): the last apply is not the change") }
    }

    /// How the app's pin reaches the sidebar: the document and the rows in one render, or in two renders either way
    /// round (the doc store and the daemon's rows are separate observations).
    enum Arrival: CaseIterable { case together, layoutThenRows, rowsThenLayout }

    /// The pin as the app sends it (p1j films at 90274b0: the item showed at its Pinned slot at once and never flew, while
    /// the harness's list-only pin flew): `d` is the active workspace, the change reaches the sidebar as `arrival` says,
    /// each render followed by its layout pass. The item that draws `d` in Pinned must fly from where its row was drawn:
    /// it carries a move spring that starts on the row's frame, not on its slot.
    @Test(arguments: Arrival.allCases, [false, true])
    func anAppPinFliesTheItemFromItsRow(arrival: Arrival, active: Bool) {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness(pins: [], active: active ? Self.moved : nil)
        defer { h.window.close() }
        guard let row = h.list.rowViews[.workspace(Self.moved)] else { return #expect(Bool(false), "d has no row before the pin") }
        let rowFrame = h.list.convert(row.bounds, from: row)
        let (layout, sections) = Self.state([Self.moved])
        h.model.noteUserIntent()
        func pass() {
            h.sidebar.renderNow()
            h.sidebar.layoutSubtreeIfNeeded()
        }
        switch arrival {
        case .together:
            h.model.layout = layout
            h.model.sections = sections
            pass()
        case .layoutThenRows:
            h.model.layout = layout
            pass()
            h.model.sections = sections
            pass()
        case .rowsThenLayout:
            h.model.sections = sections
            pass()
            h.model.layout = layout
            pass()
        }
        let name = "\(arrival)\(active ? " (active)" : "")"
        guard let item = h.list.blockRegions.lazy.compactMap({ $0.itemView(workspace: Self.moved) }).first, let layer = item.layer else {
            return #expect(Bool(false), "\(name): no Pinned item draws d")
        }
        let moves = (layer.animationKeys() ?? []).filter { $0.hasPrefix("\(SidebarDragSpring.batchKey).position") }
            .compactMap { layer.animation(forKey: $0) as? CABasicAnimation }
        #expect(!moves.isEmpty, "\(name): the Pinned item does not fly (its keys: \(layer.animationKeys() ?? []))")
        // The additive spring's start offset: the item starts where the row was drawn, \(rowFrame.minY) in the list.
        let slot = h.list.convert(item.bounds, from: item)
        let offset = moves.compactMap { ($0.fromValue as? NSValue)?.pointValue.y }.reduce(0, +)
        #expect(abs(abs(offset) - abs(rowFrame.minY - slot.minY)) < 3,
                "\(name): the item starts \(offset) pt off its slot, the row was \(rowFrame.minY - slot.minY) pt off")
    }
}
