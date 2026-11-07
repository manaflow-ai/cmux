import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-11-07: "did we not remove or find adifferent solution for the drag here to pin yet in the sidebar? it's
/// super weird how when you drag ANY workspace, it shifts imediately due to that...". Every workspace drag opened
/// an empty Pinned's header and its "Drop here to pin" row at the top as it lifted, so every row moved down by
/// them the moment a drag started. A drag's start moves no row: the zone opens only as the pointer reaches the top
/// edge, on the drag's spring like any gap, and takes the drop there.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarDragStartKeepsRowsTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let loose = ["a", "b", "c", "d", "e"].map(WorkspaceID.init)
    static let home = LayoutItem(id: LayoutItemID("itm_home"), ref: SidebarLayoutDocument.homeRef)

    /// An empty Pinned over five loose rows: on the list's own sections, or (`document`) on the sidebar document with
    /// Home's block on top, as the nightly draws it.
    static func list(document: Bool) -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let rows = SidebarSection(kind: .machine(machine), nodes: loose.map { .workspace(SidebarWorkspace(id: $0, title: $0.rawValue)) })
        let model: SidebarModel
        let list: SidebarListView
        if document {
            let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, arrangement: .list, items: [home])
            let pinned = SidebarLayoutDocument.pinnedSection(items: [])
            model = SidebarModel(sections: [
                SidebarSection(kind: .custom(SidebarCustomSection(id: top.id.rawValue)), nodes: []),
                SidebarSection(kind: .custom(SidebarCustomSection(id: pinned.id.rawValue)), nodes: []),
                rows,
            ])
            list = SidebarListView(model: model)
            var metrics = SidebarRegionMetrics.standard
            metrics.trailingTrim = SidebarStyle.rowTrailingTrim
            list.blocks = SidebarListBlocks(sections: [top.id.rawValue: top, pinned.id.rawValue: pinned], infos: [home.id: .fallback(for: home)],
                                            collapsed: [], look: .quiet, metrics: metrics, drawsLines: false, appHeights: [:])
            let keys = [home.id.rawValue, top.id.rawValue, pinned.id.rawValue, "sec_m_local"] + loose.map { "itm_" + $0.rawValue }
            model.docDrag = SidebarDocDrag(item: { key in
                if case let .workspace(id) = key { return "itm_" + id.rawValue }
                return nil
            }, section: { id in
                if case .machine = id { return "sec_m_local" }
                return nil
            }, begin: { dragged in
                Dictionary(uniqueKeysWithValues: keys.map { key in
                    (key, dragged.contains(key) ? SidebarDocAcceptance(before: false, into: false, after: false, refusal: "self")
                        : SidebarDocAcceptance(before: true, into: true, after: true))
                })
            }, drop: { _, _ in })
        } else {
            model = SidebarModel(sections: [SidebarSection(kind: .pinned, nodes: []), rows])
            list = SidebarListView(model: model)
        }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        list.leftButtonIsDown = { false }
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        return (list, window)
    }

    static func ys(_ list: SidebarListView, except hidden: Set<SidebarRowKey>) -> [SidebarRowKey: CGFloat] {
        Dictionary(uniqueKeysWithValues: list.displayed.rows.filter { !hidden.contains($0.key) }.map { ($0.key, $0.y) })
    }

    /// Pinned's header or its drop row.
    static func isZone(_ key: SidebarRowKey) -> Bool {
        switch key {
        case let .section(id), let .emptySection(id): id == .pinned || id == .custom(SidebarLayoutDocument.pinnedSectionID.rawValue)
        default: false
        }
    }

    static func zoneShows(_ list: SidebarListView) -> Bool {
        list.displayed.rows.contains { isZone($0.key) }
    }

    /// Lifts `c` from its middle.
    static func lift(_ list: SidebarListView) throws -> (SidebarListDrag, NSPoint) {
        let row = try #require(list.displayed.row(for: dragged))
        let start = NSPoint(x: 80, y: row.y + row.height / 2)
        list.press = SidebarPress(key: dragged, point: start)
        list.beginDrag(try #require(list.press))
        return (try #require(list.drag, "c did not lift"), start)
    }

    static let dragged = SidebarRowKey.workspace(WorkspaceID("c"))

    /// The drag lifts `c` and moves it a few points down and back: every other row keeps its y, and no Pinned
    /// header or drop row shows.
    @Test(arguments: [false, true]) func aDragStartKeepsEveryRowsY(_ document: Bool) throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let (list, window) = Self.list(document: document)
        defer { window.close() }
        try #require(!Self.zoneShows(list), "Pinned shows before the drag")
        let dragged = Self.dragged
        let before = Self.ys(list, except: [dragged])
        let (drag, start) = try Self.lift(list)
        try #require(document == (drag.docItems != nil), "the drag is not on the \(document ? "document" : "list")")

        var failures: [String] = []
        func check(_ step: String) {
            if Self.zoneShows(list) { failures.append("\(step): the empty Pinned zone shows") }
            for (key, y) in Self.ys(list, except: [dragged]) where before[key].map({ abs($0 - y) > 0.5 }) ?? true {
                failures.append("\(step): \(key) at y \(y), was \(before[key].map { "\($0)" } ?? "not shown")")
            }
        }
        check("lift")
        for dy in [CGFloat(3), 6, 3, -3, -6] {
            list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: start.y + dy), to: nil))
            check("move to \(dy) pt")
        }
        #expect(failures.isEmpty, "\(failures.prefix(12).joined(separator: "\n"))")
        list.cancelDrag()
    }
}
