import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-20 (screenshot of the sidebar's right edge): "Make sure this is the line ...
/// the blue dots and the loading indicators", then "line everything up with the group header's
/// down chevron". The group header's chevron center is the reference x; every row's trailing
/// indicator (the unread dot, the working spinner), grouped or loose, centers on that same x at
/// every density and sidebar width, and the dot and the spinner fill one slot of one size, so a
/// row that swaps one for the other moves nothing.
@MainActor @Suite(.serialized) struct SidebarTrailingColumnTests {
    private static let group = GroupID("grp-column")
    private static let groupedDot = WorkspaceID("ws-grouped-dot")
    private static let groupedSpinner = WorkspaceID("ws-grouped-spinner")
    private static let looseDot = WorkspaceID("ws-loose-dot")
    private static let looseSpinner = WorkspaceID("ws-loose-spinner")
    private static let indicatorRows = [groupedDot, groupedSpinner, looseDot, looseSpinner]

    nonisolated struct Look: Sendable, CustomTestStringConvertible {
        var density: SidebarDensity
        var width: CGFloat
        var testDescription: String { "\(density) at \(Int(width)) pt" }
    }

    nonisolated static let looks: [Look] = [SidebarDensity.compact, .comfortable, .expanded].flatMap { density in
        [CGFloat(200), 260, 340].map { Look(density: density, width: $0) }
    }

    private static func sidebar(_ look: Look) -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        func row(_ id: WorkspaceID, _ title: String, unread: UnreadState = .none,
                 activity: StatusIndicatorState = .idle) -> SidebarWorkspace {
            // A working spinner draws only while an agent works in the row (WORKING-AND-LOADING-INDICATORS).
            SidebarWorkspace(id: id, title: title, agentWorking: activity != .idle, kind: .terminal, unread: unread, activity: activity)
        }
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .group(SidebarGroup(id: group, name: "cmux-next app", color: .blue, isCollapsed: false, workspaces: [
                    row(groupedDot, "redesigning source control", unread: .dot),
                    row(groupedSpinner, "keyboard shortcuts", activity: .working(progress: nil)),
                ])),
                .workspace(row(looseDot, "Settings perf", unread: .count(2))),
                .workspace(row(looseSpinner, "Idle CPU, memory", activity: .working(progress: nil))),
            ]),
        ])
        let sidebar = SidebarView(model: model, design: .shared)
        sidebar.frame = NSRect(x: 0, y: 0, width: look.width, height: 600)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }

    private static func withDensity<T>(_ density: SidebarDensity, _ body: () throws -> T) rethrows -> T {
        let before = DesignSettings.shared.sidebarSections.density
        DesignSettings.shared.sidebarSections.density = density
        defer { DesignSettings.shared.sidebarSections.density = before }
        return try body()
    }

    /// The header chevron's frame in the list's coordinates.
    private static func chevron(_ sidebar: SidebarView) throws -> CGRect {
        let header = try #require(sidebar.list.rowViews[.group(group)] as? GroupHeaderRowView)
        let frame = try #require(header.debugDisclosure?.frame)
        return header.convert(frame, to: sidebar.list)
    }

    /// A row's one trailing glyph (the dot or the spinner) in the list's coordinates.
    private static func glyph(_ sidebar: SidebarView, _ id: WorkspaceID) throws -> CGRect {
        let row = try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView)
        #expect(!row.rowBadge.isHidden, "\(id): no trailing glyph")
        let frame = try #require(row.rowBadge.glyphFrames.last, "\(id): no trailing glyph")
        return row.rowBadge.convert(frame, to: sidebar.list)
    }

    @Test(arguments: looks)
    func dotsAndSpinnersCenterOnTheHeaderChevron(_ look: Look) throws {
        try Self.withDensity(look.density) {
            let sidebar = Self.sidebar(look)
            let reference = try Self.chevron(sidebar).midX
            for id in Self.indicatorRows {
                let glyph = try Self.glyph(sidebar, id)
                #expect(abs(glyph.midX - reference) <= 0.5,
                        "\(look.testDescription): \(id) glyph center x \(glyph.midX), header chevron center x \(reference)")
            }
        }
    }

    @Test(arguments: looks)
    func dotsAndSpinnersShareOneSlot(_ look: Look) throws {
        try Self.withDensity(look.density) {
            let sidebar = Self.sidebar(look)
            let slots = try Self.indicatorRows.map { try Self.glyph(sidebar, $0).size }
            #expect(Set(slots.map { "\($0.width)x\($0.height)" }).count == 1, "\(look.testDescription): slot sizes \(slots)")
        }
    }

    @Test(arguments: looks)
    func eachGlyphCentersVerticallyInItsRow(_ look: Look) throws {
        try Self.withDensity(look.density) {
            let sidebar = Self.sidebar(look)
            for id in Self.indicatorRows {
                let row = try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView)
                let glyph = try Self.glyph(sidebar, id)
                let rowFrame = row.convert(row.bounds, to: sidebar.list)
                #expect(abs(glyph.midY - rowFrame.midY) <= 0.5,
                        "\(look.testDescription): \(id) glyph center y \(glyph.midY), row center y \(rowFrame.midY)")
            }
        }
    }

    // MARK: Every row kind (Lawrence msg 11914)

    /// Lawrence msg 11914: "the home blue dot isn't lined up with the other trailing dots", and msg 11959:
    /// "trailing dots and spinners must line up horizontally across sections"; msg 12086: "loading spinners must
    /// align too". Every visible trailing dot and spinner centers on the column in every row kind: Home, a
    /// selected band item that needs you, a band item that works (a spinner alone), the band's pinned
    /// collapsed-loading group header, a selected list row that works (its disclosure shown), a row that
    /// needs you, an unread row, a busy row (a spinner alone), open group headers' chevrons at depth 0 and 1, collapsed groups'
    /// resting spinners at depth 0 and 2, a member and a nested member, at every density with Minimal Mode
    /// on and off. The band item drew its yellow dot after its title, 3.5 pt
    /// right of the column. Each case prints a `TRAILCOL|` line so a fleet log shows the numbers.
    nonisolated struct KindCase: CustomTestStringConvertible, Sendable {
        var density: SidebarDensity
        var minimal: SidebarMinimalMode
        var width: CGFloat
        var testDescription: String { "\(density.rawValue)/minimal-\(minimal.rawValue)/\(Int(width))pt" }
    }

    nonisolated static let kindCases: [KindCase] = SidebarDensity.allCases.flatMap { density in
        [SidebarMinimalMode.off, .both].flatMap { minimal in [220, 300].map { KindCase(density: density, minimal: minimal, width: $0) } }
    }

    static let home = LayoutItemID("itm_home"), lead = LayoutItemID("itm_lead"), browserLead = LayoutItemID("itm_browser_lead")
    static let selected = WorkspaceID("tc-selected"), unread = WorkspaceID("tc-unread"), busy = WorkspaceID("tc-busy")
    static let waiting = WorkspaceID("tc-waiting")
    static let member = WorkspaceID("tc-member"), nested = WorkspaceID("tc-nested"), loading = WorkspaceID("tc-loading")
    static let open = GroupID("tc-open"), sub = GroupID("tc-sub"), folded = GroupID("tc-folded")
    static let pinned = GroupID("tc-pinned"), deep = GroupID("tc-deep")
    static let pinnedMember = WorkspaceID("tc-pinned-member"), deepMember = WorkspaceID("tc-deep-member")
    /// Inner tab rows (Leo 2026-10-28, "because it's the inner tab thing"): an unread tab and a working tab under
    /// the selected row at depth 0, and under a member of a nested group.
    static let tabUnread = TabID("tc-tab-1"), tabWorking = TabID("tc-tab-2")
    static let nestedTabUnread = TabID("tc-nested-tab-1"), nestedTabWorking = TabID("tc-nested-tab-2")
    static func tab(_ id: TabID, _ title: String, unread: Bool = false, working: Bool = false) -> SidebarTab {
        var tab = SidebarTab(id: id, title: title, isUnread: unread)
        if working { tab.state = .working }
        return tab
    }
    static let topKey = SidebarRowKey.block(SidebarLayoutDocument.topSectionID.rawValue)

    /// The band (Home unread, a selected band workspace that needs you) over a list with every row kind.
    final class KindHarness {
        let model: SidebarModel
        let sidebar: SidebarView
        let window: NSWindow
        var list: SidebarListView { sidebar.list }

        init(width: CGFloat) {
            _ = NSApplication.shared
            typealias T = SidebarTrailingColumnTests
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, items: [
                LayoutItem(id: T.home, ref: .builtIn(.home)),
                LayoutItem(id: T.lead, ref: .workspace("tc-band-lead")),
                LayoutItem(id: T.browserLead, ref: .workspace("tc-band-browser")),
            ])
            // Lawrence msg 11959: the band's pinned group header ("Agents & routing", collapsed, loading).
            let block = SidebarSection(kind: .custom(SidebarCustomSection(id: SidebarLayoutDocument.topSectionID.rawValue)), nodes: [
                .group(SidebarGroup(id: T.pinned, name: "Agents & routing", color: .purple, isCollapsed: true, isPinned: true,
                                    workspaces: [SidebarWorkspace(id: T.pinnedMember, title: "subrouter", agentWorking: true, activity: .working)])),
            ])
            // A header two levels in (it reaches left over its rail), collapsed and loading.
            var deepGroup = SidebarGroup(id: T.deep, name: "Deep loading", color: .green, isCollapsed: true,
                                         workspaces: [SidebarWorkspace(id: T.deepMember, title: "Deep member", agentWorking: true, activity: .working)])
            deepGroup.parent = T.sub
            var subgroup = SidebarGroup(id: T.sub, name: "Perf", color: .yellow,
                                        workspaces: [SidebarWorkspace(id: T.nested, title: "Nested unread", unread: .dot,
                                                                      tabs: [T.tab(T.nestedTabUnread, "claude", unread: true),
                                                                             T.tab(T.nestedTabWorking, "codex", working: true)])])
            subgroup.parent = T.open
            let nodes: [SidebarNode] = [
                // Lawrence msg 12086: "loading spinners must align too": the selected row works (a spinner).
                .workspace(SidebarWorkspace(id: T.selected, title: "Selected working", agentWorking: true, activity: .working,
                                            tabs: [T.tab(T.tabUnread, "zsh", unread: true), T.tab(T.tabWorking, "vim", working: true)])),
                .group(SidebarGroup(id: T.open, name: "cmux-next app", color: .blue,
                                    workspaces: [SidebarWorkspace(id: T.member, title: "Member unread", unread: .dot)])),
                .group(subgroup),
                .group(deepGroup),
                .group(SidebarGroup(id: T.folded, name: "Folded loading", color: .blue, isCollapsed: true,
                                    workspaces: [SidebarWorkspace(id: T.loading, title: "Loading member", agentWorking: true, activity: .working)])),
                .workspace(SidebarWorkspace(id: T.busy, title: "subrouter 2", agentWorking: true, activity: .working)),
                .workspace(SidebarWorkspace(id: T.unread, title: "Tailscale SSH audit", unread: .dot)),
                .workspace(SidebarWorkspace(id: T.waiting, title: "Needs you", agentWorking: true, activity: .waiting)),
            ]
            model = SidebarModel(sections: [block, SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: T.selected)
            // The selected row's disclosure keeps its slot (cx-fo2t) where tab rows list.
            model.showWorkspaceTabs = true
            let layout = SidebarLayoutDocument(sections: [top])
            model.layout = layout
            var homeInfo = SidebarItemInfo(title: "Home", symbol: "house")
            homeInfo.unreadDot = true
            var leadInfo = SidebarItemInfo(title: "cmux Performance Lead", symbol: "textformat", isActive: true)
            leadInfo.textOnly = true
            leadInfo.activity = .waiting
            // A band item that works: its spinner and nothing else (msg 12086).
            var browserInfo = SidebarItemInfo(title: "Computer & browser use lead", symbol: "textformat")
            browserInfo.textOnly = true
            browserInfo.activity = .working
            model.itemInfo = [T.home: homeInfo, T.lead: leadInfo, T.browserLead: browserInfo]
            model.docDrag = SidebarDocDrag(item: { _ in nil }, section: { _ in nil }, begin: { _ in [:] }, drop: { _, _ in }, adoptRef: { _ in nil })
            sidebar = SidebarView(model: model, design: DesignSettings.shared)
            sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 900)
            // Clear of the pointer, so no row starts hovered: only the tests that hover a row do.
            let pointer = NSEvent.mouseLocation
            window = NSWindow(contentRect: NSRect(x: pointer.x + 40, y: pointer.y - 450, width: width, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(sidebar)
            window.orderFrontRegardless()
            sidebar.layoutSubtreeIfNeeded()
            list.reload(animated: false)
            sidebar.layoutSubtreeIfNeeded()
            list.fitToClip()
            sidebar.layoutSubtreeIfNeeded()
            for row in list.rowViews.values {
                row.layoutSubtreeIfNeeded()
                if let block = row as? SidebarBlockRowView { block.region.itemViews.values.forEach { $0.layoutSubtreeIfNeeded() } }
            }
        }

        func bandRow(_ id: LayoutItemID) throws -> SidebarItemRowView {
            let block = try #require(list.rowViews[SidebarTrailingColumnTests.topKey] as? SidebarBlockRowView, "no top block")
            return try #require(block.region.itemViews[id], "no band row \(id.rawValue)")
        }

        func row(_ key: SidebarRowKey) throws -> NSView {
            try #require(list.rowViews[key], "no row \(key)")
        }
    }

    /// One visible trailing indicator: what drew it and its center x in list points.
    struct Mark: CustomStringConvertible {
        var what: String
        var midX: CGFloat
        /// The mark's center y less its row's center y, in list points.
        var dy: CGFloat = 0
        var description: String { "\(what)@\(midX),dy\(dy)" }
    }

    /// The opacity `view` draws with, up to `root`.
    static func drawnAlpha(_ view: NSView, below root: NSView) -> CGFloat {
        var alpha: CGFloat = 1, cursor: NSView? = view
        while let v = cursor, v !== root { alpha *= v.alphaValue; cursor = v.superview }
        return alpha
    }

    /// Every visible dot and spinner in `row` (and a group header's shown chevron), in list x.
    static func marks(in row: NSView, named name: String, list: SidebarListView) -> [Mark] {
        var found: [Mark] = []
        let rowMidY = list.convert(row.bounds, from: row).midY
        func add(_ what: String, _ frame: CGRect) {
            found.append(Mark(what: "\(name).\(what)", midX: frame.midX, dy: frame.midY - rowMidY))
        }
        func visit(_ view: NSView) {
            guard !view.isHidden, drawnAlpha(view, below: list) > 0.01 else { return }
            if let badge = view as? RowBadgeView, let glyph = badge.glyphFrames.last {
                add("dot", list.convert(glyph, from: badge))
            } else if let indicator = view as? StatusIndicatorView, indicator.showsGlyph {
                add("status", list.convert(indicator.bounds, from: indicator))
            } else if let badge = view as? UnreadBadgeView, badge.state == .dot {
                add("unreadDot", list.convert(badge.bounds, from: badge))
            }
            view.subviews.forEach(visit)
        }
        visit(row)
        if let header = row as? GroupHeaderRowView, let chevron = header.debugDisclosure, chevron.shown {
            add("chevron", list.convert(chevron.frame, from: header))
        }
        return found
    }

    /// The column x itself: where the open group header's chevron centers.
    static func columnX(_ h: KindHarness) throws -> CGFloat {
        let header = try #require(h.list.rowViews[.group(open)] as? GroupHeaderRowView)
        let chevron = try #require(header.debugDisclosure)
        return h.list.convert(chevron.frame, from: header).midX
    }

    @Test(arguments: kindCases)
    func everyRowKindCentersItsIndicatorOnTheColumn(_ c: KindCase) throws {
        try SidebarGroupRailAlignmentTests.with(c.density, c.minimal) {
            let h = KindHarness(width: c.width)
            defer { h.window.close() }
            let column = try Self.columnX(h)
            let rows: [(String, NSView)] = [
                ("home", try h.bandRow(Self.home)), ("bandSelected", try h.bandRow(Self.lead)),
                ("bandWorking", try h.bandRow(Self.browserLead)), ("waiting", try h.row(.workspace(Self.waiting))),
                ("selected", try h.row(.workspace(Self.selected))), ("unread", try h.row(.workspace(Self.unread))),
                ("busy", try h.row(.workspace(Self.busy))), ("member", try h.row(.workspace(Self.member))),
                ("nested", try h.row(.workspace(Self.nested))), ("openHeader", try h.row(.group(Self.open))),
                ("nestedOpenHeader", try h.row(.group(Self.sub))), ("deepLoadingHeader", try h.row(.group(Self.deep))),
                ("foldedHeader", try h.row(.group(Self.folded))), ("pinnedLoadingHeader", try h.row(.group(Self.pinned))),
                ("tabUnread", try h.row(.tab(Self.selected, Self.tabUnread))), ("tabWorking", try h.row(.tab(Self.selected, Self.tabWorking))),
                ("nestedTabUnread", try h.row(.tab(Self.nested, Self.nestedTabUnread))),
                ("nestedTabWorking", try h.row(.tab(Self.nested, Self.nestedTabWorking))),
            ]
            var marks: [Mark] = []
            for (name, row) in rows {
                let own = Self.marks(in: row, named: name, list: h.list)
                #expect(!own.isEmpty, "\(c.testDescription): \(name) shows no trailing dot, spinner or chevron")
                marks += own
            }
            print("TRAILCOL|\(c.testDescription)|column \(column)|\(marks.map(\.description).joined(separator: " "))")
            for mark in marks {
                #expect(abs(mark.midX - column) <= 0.5, "\(c.testDescription): \(mark.what) centers at \(mark.midX), the column at \(column)")
            }
            // One center line per row: the tab rows and the headers, one line tall, center their marks on it.
            for mark in marks where ["tab", "header"].contains(where: mark.what.lowercased().contains) {
                #expect(abs(mark.dy) <= 0.5, "\(c.testDescription): \(mark.what) sits \(mark.dy) pt off its row's center")
            }
        }
    }

    /// Leo 2026-10-28: "If you're hovering over a workspace or whatever, just don't show the spinner." While a
    /// row's hover controls show, no dot or spinner draws in it; at the row's end (the default close spot) a
    /// control takes the column, and under every spot the controls stay inside the row. A hovered group header
    /// shows its chevron on the column and no spinner. Each case prints a `TRAILHOVER|` line.
    @Test(arguments: SidebarDensity.allCases, [SidebarRowCloseSpot.end, .middle, .even])
    func hoverControlsTakeTheMarksPlace(_ density: SidebarDensity, _ spot: SidebarRowCloseSpot) throws {
        try SidebarTabGroupControlsTests.withCloseSpot(spot) { try SidebarGroupRailAlignmentTests.with(density, .off) {
            let h = KindHarness(width: 260)
            defer { h.window.close() }
            let column = try Self.columnX(h)
            var report: [String] = []
            for id in [Self.unread, Self.selected, Self.busy, Self.waiting, Self.member, Self.nested] {
                let row = try #require(h.list.rowViews[.workspace(id)] as? WorkspaceRowView)
                row.isHovered = true
                row.layoutSubtreeIfNeeded()
                defer { row.isHovered = false; row.layoutSubtreeIfNeeded() }
                let label = "\(density.rawValue)/\(spot.rawValue) \(id.rawValue) hovered"
                let controls = ([row.closeButton, row.moreButton, row.pinButton] as [NSView]).filter { !$0.isHidden && $0.alphaValue > 0 }
                #expect(!controls.isEmpty, "\(label): no hover control shows")
                let marks = Self.marks(in: row, named: id.rawValue, list: h.list)
                #expect(marks.isEmpty, "\(label): \(marks) draw beside the hover controls")
                let centers = controls.map { h.list.convert($0.frame, from: row).midX }
                report.append("\(id.rawValue) controls \(centers) marks \(marks.count)")
                if spot.atEnd {
                    #expect(centers.contains { abs($0 - column) <= 0.5 }, "\(label): no control on the column \(column): \(centers)")
                }
                for control in controls {
                    #expect(control.frame.minX >= 0 && control.frame.maxX <= row.bounds.width, "\(label): a hover control leaves its row")
                }
            }
            for id in [Self.open, Self.sub, Self.folded, Self.deep] {
                let header = try #require(h.list.rowViews[.group(id)] as? GroupHeaderRowView)
                header.isHovered = true
                header.layoutSubtreeIfNeeded()
                defer { header.isHovered = false; header.layoutSubtreeIfNeeded() }
                let marks = Self.marks(in: header, named: id.rawValue, list: h.list)
                report.append("\(id.rawValue) \(marks)")
                #expect(marks.map(\.what) == ["\(id.rawValue).chevron"], "\(density.rawValue) \(id.rawValue) hovered: \(marks)")
                for mark in marks { #expect(abs(mark.midX - column) <= 0.5, "\(id.rawValue) hovered: chevron at \(mark.midX), column \(column)") }
            }
            print("TRAILHOVER|\(density.rawValue)/\(spot.rawValue)|column \(column)|\(report.joined(separator: "; "))")
        } }
    }

    /// Codex review: with motion on, the pointer leaving a row or a loading header clears its controls at once while
    /// the mark comes back, so no frame of the fade draws both on the column.
    /// The `trailing` badge style puts the unread count where the close lands: it too returns on an empty slot.
    @Test(arguments: [SidebarRowCloseSpot.end, .middle], [SidebarRowBadgeStyle.corner, .trailing])
    func leavingClearsTheControlsBeforeTheMarkReturns(_ spot: SidebarRowCloseSpot, _ style: SidebarRowBadgeStyle) throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        try SidebarTabGroupControlsTests.withCloseSpot(spot) { try SidebarGroupRailAlignmentTests.with(.comfortable, .off) {
            let h = KindHarness(width: 260)
            h.model.rowBadgeStyle = style
            h.list.reload(animated: false)
            h.sidebar.layoutSubtreeIfNeeded()
            defer { h.window.close() }
            @MainActor func drawn(_ view: NSView) -> Bool { !view.isHidden && Self.drawnAlpha(view, below: h.list) > 0.01 }
            for id in [Self.busy, Self.unread, Self.waiting] {
                let row = try #require(h.list.rowViews[.workspace(id)] as? WorkspaceRowView)
                row.isHovered = true
                row.layoutSubtreeIfNeeded()
                row.isHovered = false
                row.layoutSubtreeIfNeeded()
                let controls = ([row.closeButton, row.moreButton, row.pinButton] as [NSView]).filter(drawn)
                #expect(controls.isEmpty, "\(spot.rawValue)/\(style.rawValue) \(id.rawValue): a hover control still draws as the mark returns")
            }
            for id in [Self.folded, Self.deep] {
                let header = try #require(h.list.rowViews[.group(id)] as? GroupHeaderRowView)
                header.isHovered = true
                header.layoutSubtreeIfNeeded()
                header.isHovered = false
                header.layoutSubtreeIfNeeded()
                let marks = Self.marks(in: header, named: id.rawValue, list: h.list).map(\.what)
                #expect(marks == ["\(id.rawValue).status"], "\(id.rawValue): \(marks) as the hover ends")
                #expect(!drawn(header.moreButton) && !drawn(header.addButton), "\(id.rawValue): + or more still draws as the spinner returns")
            }
        } }
    }
}
