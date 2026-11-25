import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-11-07: "did we not remove or find adifferent solution for the drag here to pin yet in the sidebar? it's
/// super weird how when you drag ANY workspace, it shifts imediately due to that...". Every workspace drag opened
/// an empty Pinned's header and its "Drop here to pin" row at the top as it lifted, so every row moved down by
/// them the moment a drag started. A drag's start moves no row: the zone opens only as the pointer reaches the top
/// edge (`SidebarPinZone`), on the drag's spring like any gap, and takes the drop there.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarDragStartKeepsRowsTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let loose = ["a", "b", "c", "d", "e"].map(WorkspaceID.init)
    static let home = LayoutItem(id: LayoutItemID("itm_home"), ref: SidebarLayoutDocument.homeRef)

    /// An empty Pinned over five loose rows: on the list's own sections, or (`document`) on the sidebar document with
    /// Home's block on top, as the nightly draws it.
    static func list(document: Bool, pins: [LayoutItem] = [], extra: [LayoutSection] = [], refusesPins: Bool = false) -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let rows = SidebarSection(kind: .machine(machine), nodes: loose.map { .workspace(SidebarWorkspace(id: $0, title: $0.rawValue)) })
        let extraSections = extra.map { SidebarSection(kind: .custom(SidebarCustomSection(id: $0.id.rawValue)), nodes: []) }
        let model: SidebarModel
        let list: SidebarListView
        if document {
            let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, arrangement: .list, items: [home])
            let pinned = SidebarLayoutDocument.pinnedSection(items: pins)
            model = SidebarModel(sections: [
                SidebarSection(kind: .custom(SidebarCustomSection(id: top.id.rawValue)), nodes: []),
                SidebarSection(kind: .custom(SidebarCustomSection(id: pinned.id.rawValue)), nodes: []),
                rows,
            ] + extraSections)
            list = SidebarListView(model: model)
            var metrics = SidebarRegionMetrics.standard
            metrics.trailingTrim = SidebarStyle.rowTrailingTrim
            list.blocks = SidebarListBlocks(sections: Dictionary(uniqueKeysWithValues: ([top, pinned] + extra).map { ($0.id.rawValue, $0) }), infos: Dictionary(uniqueKeysWithValues: ([home] + pins).map { ($0.id, SidebarItemInfo.fallback(for: $0)) }),
                                            collapsed: [], look: .quiet, metrics: metrics, drawsLines: false, appHeights: [:])
            let keys = [home.id.rawValue, top.id.rawValue, pinned.id.rawValue, "sec_m_local"] + extra.map(\.id.rawValue) + pins.map(\.id.rawValue) + loose.map { "itm_" + $0.rawValue }
            model.docDrag = SidebarDocDrag(item: { key in
                if case let .workspace(id) = key { return "itm_" + id.rawValue }
                return nil
            }, section: { id in
                if case .machine = id { return "sec_m_local" }
                return nil
            }, begin: { dragged in
                Dictionary(uniqueKeysWithValues: keys.map { key in
                    (key, dragged.contains(key) ? SidebarDocAcceptance(before: false, into: false, after: false, refusal: "self")
                        : refusesPins && key == pinned.id.rawValue ? SidebarDocAcceptance(before: false, into: false, after: false, refusal: "pinned_area")
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

    /// Up to the top edge: the zone opens where Pinned goes and takes the drop (its row, or the drop's gap in its
    /// place), and the rows between it and the lifted one move down together; back down, it closes.
    @Test(arguments: [false, true]) func theTopEdgeOpensPinnedsZone(_ document: Bool) throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let (list, window) = Self.list(document: document)
        defer { window.close() }
        let dragged = Self.dragged
        let before = Self.ys(list, except: [dragged])
        let (drag, start) = try Self.lift(list)
        let pinned = try #require(drag.zones.first { $0.id == SidebarDocStore.pinnedSection }, "no zone to open for an empty Pinned")
        let zone = pinned.at...(pinned.at + pinned.height)
        let origin = try #require(list.displayed.row(for: dragged)).y
        let above = Self.ys(list, except: [dragged]).filter { $0.value >= zone.lowerBound - 0.5 && $0.value < origin }
        let first = try #require(above.min { $0.value < $1.value }, "no row above the lifted one")
        var y = start.y
        while y > zone.lowerBound + 4 {
            y = max(zone.lowerBound + 4, y - 6)
            list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: y), to: nil))
        }
        #expect(drag.openZone == SidebarDocStore.pinnedSection, "the drag reached the top edge and the zone stayed shut")
        let moved = try #require(list.displayed.row(for: first.key)).y - first.value
        #expect(moved >= (zone.upperBound - zone.lowerBound) / 2, "the first row moved \(moved) pt, under a zone \(zone.upperBound - zone.lowerBound) pt tall")
        for key in above.keys {
            let shift = (list.displayed.row(for: key)?.y ?? 0) - (before[key] ?? 0)
            #expect(abs(shift - moved) < 0.5, "\(key) moved \(shift) pt, the first row \(moved) pt")
        }
        if !document {
            guard case let .position(position)? = drag.target else { Issue.record("no drop at the top edge: \(String(describing: drag.target))"); return }
            #expect(position.section == .pinned, "the top edge drops in \(position.section), not Pinned")
        } else {
            #expect(drag.docTarget != nil, "the top edge takes no drop on the document")
        }

        // Back down past the zone: it closes.
        let down = start.y + list.metrics.rowHeight
        while y < down {
            y = min(down, y + 6)
            list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: y), to: nil))
        }
        #expect(drag.openZone == nil && !Self.zoneShows(list), "the zone stayed open with the pointer back under it")
        list.cancelDrag()
    }

    /// A Pinned that keeps items opens no zone: a drag up past its block draws no "Drop here to pin" row under it.
    @Test func aPinnedWithItemsOpensNoZone() throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let pin = LayoutItem(id: LayoutItemID("itm_pin"), ref: .workspace("local:ws-pin"))
        let (list, window) = Self.list(document: true, pins: [pin])
        defer { window.close() }
        let (drag, start) = try Self.lift(list)
        #expect(!drag.zones.contains { $0.id == SidebarDocStore.pinnedSection }, "a Pinned with items has a zone to open")
        var y = start.y
        while y > 2 {
            y = max(2, y - 6)
            list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: y), to: nil))
            #expect(!list.displayed.rows.contains { $0.key == .emptySection(.custom(SidebarLayoutDocument.pinnedSectionID.rawValue)) },
                    "a drop row shows under a Pinned with items at y \(y)")
        }
        list.cancelDrag()
    }

    /// An empty titled section under the list: no drop row at the lift; its zone opens as the pointer reaches its
    /// title, and takes the drop.
    @Test func anEmptyTitledSectionOpensAtItsTitle() throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let later = LayoutSection(id: LayoutSectionID("sec_later"), title: "Later", region: .top, items: [])
        let (list, window) = Self.list(document: true, extra: [later])
        defer { window.close() }
        let block = try #require(list.displayed.row(for: .block("sec_later")), "the empty titled section draws no title")
        let (drag, start) = try Self.lift(list)
        let zoneRow = SidebarRowKey.emptySection(.custom("sec_later"))
        #expect(list.displayed.row(for: zoneRow) == nil, "the empty section's drop row shows at the lift")
        #expect(drag.zones.contains { $0.id == "sec_later" }, "no zone to open for the empty section")
        var y = start.y
        let title = block.y + block.height / 2
        while abs(y - title) > 0.5 {
            y = y < title ? min(title, y + 6) : max(title, y - 6)
            list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: y), to: nil))
        }
        #expect(drag.openZone == "sec_later", "the pointer on the title did not open its zone")
        #expect(drag.docTarget != nil, "the empty section takes no drop at its title")
        list.cancelDrag()
    }

    /// A drag of the list's only pinned row keeps Pinned's header and zone for the whole drag: out to the list and
    /// back, it still drops in Pinned.
    @Test func theLastPinnedRowCanGoBack() throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        _ = NSApplication.shared
        let pinned = WorkspaceID("p")
        let model = SidebarModel(sections: [
            SidebarSection(kind: .pinned, nodes: [.workspace(SidebarWorkspace(id: pinned, title: "p"))]),
            SidebarSection(kind: .machine(Self.machine), nodes: Self.loose.map { .workspace(SidebarWorkspace(id: $0, title: $0.rawValue)) }),
        ])
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        list.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(list)
        defer { window.close() }
        list.leftButtonIsDown = { false }
        window.orderFrontRegardless()
        list.reload(animated: false)
        let row = try #require(list.displayed.row(for: .workspace(pinned)))
        let start = NSPoint(x: 80, y: row.y + row.height / 2)
        list.press = SidebarPress(key: .workspace(pinned), point: start)
        list.beginDrag(try #require(list.press))
        let drag = try #require(list.drag)
        #expect(drag.keepsPinned, "the lift did not keep the Pinned it empties")
        #expect(list.displayed.row(for: .section(.pinned)) != nil, "Pinned's header left at the lift")
        let bottom = (list.displayed.rows.last?.maxY ?? 200) - 4
        var y = start.y
        for target in [bottom, start.y] {
            while abs(y - target) > 0.5 {
                y = y < target ? min(target, y + 6) : max(target, y - 6)
                list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: y), to: nil))
                #expect(list.displayed.row(for: .section(.pinned)) != nil, "Pinned's header left at y \(y)")
            }
        }
        guard case let .position(position)? = drag.target else { Issue.record("no drop back in Pinned: \(String(describing: drag.target))"); return }
        #expect(position.section == .pinned, "back over its slot, the drop goes to \(position.section)")
        list.cancelDrag()
    }

    /// A group dragged up to an empty titled section above it opens that section's zone and drops there: its plan,
    /// made again with the zone open, keeps the group's own place as its origin, so the release is no cancel.
    /// The document's Pinned refuses an item from outside it, as `SidebarDocRecords.keepingPinned` does (Pin is the
    /// way in): it opens no zone that would take nothing, at the lift or at the top edge.
    @Test func aPinnedThatRefusesOpensNoZone() throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let (list, window) = Self.list(document: true, refusesPins: true)
        defer { window.close() }
        let before = Self.ys(list, except: [Self.dragged])
        let (drag, start) = try Self.lift(list)
        #expect(!drag.zones.contains { $0.id == SidebarDocStore.pinnedSection }, "a zone for a Pinned that refuses the drag")
        var y = start.y
        while y > 2 {
            y = max(2, y - 6)
            list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: y), to: nil))
        }
        #expect(drag.openZone == nil, "the top edge opened \(drag.openZone ?? "")")
        #expect(!Self.zoneShows(list), "the refused Pinned zone shows")
        list.cancelDrag()
        list.layoutSubtreeIfNeeded()
        for (key, y) in Self.ys(list, except: []) where before[key].map({ abs($0 - y) > 0.5 }) == true {
            Issue.record("\(key) at y \(y) after the drag, was \(before[key] ?? 0)")
        }
    }

    @Test(arguments: [false, true]) func aGroupDropsIntoAnEmptySectionAboveIt(collapsed: Bool) throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        _ = NSApplication.shared
        let later = LayoutSection(id: LayoutSectionID("sec_later"), title: "Later", region: .top, items: [])
        let group = GroupID("g")
        let model = SidebarModel(sections: [
            SidebarSection(kind: .custom(SidebarCustomSection(id: later.id.rawValue)), nodes: []),
            SidebarSection(kind: .machine(Self.machine), nodes: [
                .workspace(SidebarWorkspace(id: WorkspaceID("a"), title: "a")),
                .group(SidebarGroup(id: group, name: "G", color: .green, workspaces: [SidebarWorkspace(id: WorkspaceID("g1"), title: "g1")])),
                .workspace(SidebarWorkspace(id: WorkspaceID("b"), title: "b")),
            ]),
        ])
        let list = SidebarListView(model: model)
        var metrics = SidebarRegionMetrics.standard
        metrics.trailingTrim = SidebarStyle.rowTrailingTrim
        if collapsed { model.collapsedLayoutSections = [later.id] }
        list.blocks = SidebarListBlocks(sections: [later.id.rawValue: later], infos: [:], collapsed: model.collapsedLayoutSections, look: .quiet,
                                        metrics: metrics, drawsLines: false, appHeights: [:])
        var drops: [([String], SidebarDocTarget)] = []
        let keys = ["sec_later", "sec_m_local", "itm_a", "itm_b", "itm_g1", "itm_g"]
        model.docDrag = SidebarDocDrag(item: { key in
            switch key {
            case let .workspace(id): "itm_" + id.rawValue
            case .group: "itm_g"
            default: nil
            }
        }, section: { id in
            switch id {
            case .machine: "sec_m_local"
            case let .custom(custom): custom
            default: nil
            }
        }, begin: { dragged in
            Dictionary(uniqueKeysWithValues: keys.map { key in
                (key, dragged.contains(key) ? SidebarDocAcceptance(before: false, into: false, after: false, refusal: "self")
                    : SidebarDocAcceptance(before: true, into: true, after: true))
            })
        }, drop: { items, target in drops.append((items, target)) })
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        list.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(list)
        defer { window.close() }
        list.leftButtonIsDown = { false }
        window.orderFrontRegardless()
        list.reload(animated: false)
        let block = try #require(list.displayed.row(for: .block("sec_later")), "the empty titled section draws no title")
        let header = try #require(list.displayed.row(for: .group(group)))
        let start = NSPoint(x: 80, y: header.y + header.height / 2)
        list.press = SidebarPress(key: .group(group), point: start)
        list.beginDrag(try #require(list.press))
        let drag = try #require(list.drag, "the group did not lift")
        try #require(drag.group != nil && drag.docItems != nil, "not a document group drag")
        var y = start.y
        let title = block.y + block.height / 2
        while abs(y - title) > 0.5 {
            y = max(title, y - 6)
            list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: y), to: nil))
        }
        #expect(drag.openZone == "sec_later", "the group at the title did not open its zone (collapsed: \(collapsed))")
        let plan = try #require(drag.group)
        #expect(plan.slot != plan.plan.origin, "the zone's slot is taken for the group's own place")
        list.finishDrag()
        #expect(drops.count == 1, "the release into the empty section sent \(drops.count) drops")
    }
}
