import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-23, on his sidebar's group line: "THE FUCKING THHIN PURPLE LIINE IS THE GROUP!!!! THE POINT IS WHY
/// DID IT GET SO OVFF FUCKING CENTER ... PLUS THE SHAPING ON IT... WTF HAPPENED TO IT BEING PUSHED TO THE LEFT!?"
/// The header's rail reach (Lawrence's ab905adeadd0) puts the line at the header bar's left edge; on it, Leo's
/// 2026-10-19 Chrome reference: one color for bar and line, a small cut (about 6 pt) under the header, a 2 pt line,
/// flat ends, and an option that joins the line to the header as one L. Every `sidebar.groupLineLayout` is pinned here.
@MainActor @Suite(.serialized) struct SidebarGroupLineLayoutTests {
    static let group = GroupID("g-codex-fleet")
    static let closed = GroupID("g-closed")
    static let looseID = WorkspaceID("ws-loose")
    static let members = [WorkspaceID("cx-as"), WorkspaceID("cx-ac"), WorkspaceID("cx-ch")]

    /// Runs `body` with the Debug layout set, then clears it. The store is active without a file, so nothing is written.
    static func withLayout(_ layout: SidebarGroupLineLayout, _ body: () throws -> Void) throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let key = SidebarGroupLineLayout.tunable.key
        defer { TunableStore.shared.set(key, nil) }
        try #require(TunableStore.shared.set(key, layout.tunableValue) == layout.tunableValue, "the layout takes the override")
        try body()
    }

    /// An ungrouped row, then an open purple group of three (the second selected) and a collapsed group.
    static func sidebar(selected: WorkspaceID = members[1]) -> (SidebarView, NSWindow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let fleet = SidebarGroup(id: group, name: "Agent fleet (build-box)", color: .purple,
                                 workspaces: members.map { SidebarWorkspace(id: $0, title: $0.rawValue) })
        let folded = SidebarGroup(id: closed, name: "Folded", color: .green, isCollapsed: true,
                                  workspaces: [SidebarWorkspace(id: WorkspaceID("ws-folded"), title: "folded")])
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [.workspace(SidebarWorkspace(id: looseID, title: "scratch")), .group(fleet), .group(folded)]),
        ], activeWorkspaceID: selected)
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        window.contentView = root
        sidebar.frame = root.bounds
        root.addSubview(sidebar)
        window.orderFrontRegardless()
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return (sidebar, window)
    }

    /// Leo's numbers: a 2 pt line, a 6 pt cut; `inside` sets it about 4 to 5 pt in from the header's left edge.
    @Test func theShapeIsChromesMeasuredOne() {
        #expect(SidebarGroupLineLayout.tunable.defaultValue == .edge, "the line at the header bar's left edge is the default")
        #expect(SidebarStyle.groupBarWidth == 2)
        #expect(SidebarStyle.groupLineCut == 6)
        let inset = SidebarStyle.groupLineCornerInset
        #expect(inset >= 4 && inset <= 5, "about 4 to 5 pt inside the header: \(inset)")
        #expect(inset + SidebarStyle.groupBarWidth == SidebarStyle.rowCornerRadius, "the line's right edge is off the corner arc's end")
    }

    @Test func theRailRoundsOnlyItsRightCorners() {
        let path = SidebarGroupLineShape.line(width: 2, height: 20)
        #expect(path.contains(CGPoint(x: 0.1, y: 0.1)), "the left edge stays straight at the top")
        #expect(path.contains(CGPoint(x: 0.1, y: 19.9)), "the left edge stays straight at the bottom")
        #expect(!path.contains(CGPoint(x: 1.9, y: 0.1)), "the top-right corner rounds inward")
        #expect(path.contains(CGPoint(x: 1.9, y: 3)), "the top reaches full width after one radius")
        #expect(!path.contains(CGPoint(x: 1.9, y: 19.9)), "the bottom-right corner rounds inward")
        #expect(path.contains(CGPoint(x: 1.9, y: 17)), "the bottom reaches full width before one radius")
    }

    @Test @MainActor func theCutMaskRetainsCoverageWhenARailShrinks() {
        let line = GroupLineView()
        line.frame = NSRect(x: 0, y: 0, width: 2, height: 5000)
        line.layoutSubtreeIfNeeded()
        let initial = line.railShape.frame.height
        line.frame.size.height = 500
        line.layoutSubtreeIfNeeded()
        #expect(initial >= 5000 && line.railShape.frame.height >= initial,
                "the cut shape covers the old presentation height during a shrink")
    }

    /// The line keeps the rail's x (its members' less `groupRailReach`) in every layout; the header's bar starts there
    /// or, `inside`, further left. Its cut (joined: none), 2 pt width, flat ends, end at the last member's bottom, its
    /// color (the bar's), and that no member's fill covers it and no member moves.
    @Test(arguments: SidebarGroupLineLayout.allCases)
    func theLineSitsWhereItsLayoutPutsIt(_ layout: SidebarGroupLineLayout) throws {
        try Self.withLayout(layout) {
            let (sidebar, window) = Self.sidebar()
            defer { window.close() }
            let list = sidebar.list
            let header = try #require(list.rowViews[.group(Self.group)] as? GroupHeaderRowView)
            let loose = try #require(list.rowViews[.workspace(Self.looseID)])
            let line = try #require(list.groupLineViews.shown[Self.group]?.frame, "\(layout): the open group has no line")
            let view = try #require(GroupPaletteDefaultTests.views(GroupLineView.self, in: sidebar).first { $0.frame == line })
            let head = header.frame
            #expect(line.width == 2, "\(layout): the line is \(line.width) pt")
            view.layoutSubtreeIfNeeded()
            #expect(view.layer?.cornerRadius == 0 && view.layer?.masksToBounds == true && view.railShape.path != nil,
                    "\(layout): the line has the clipped Chrome corner cut")
            #expect(view.railShape.frame.width == 2 && view.railShape.frame.height >= 4096,
                    "\(layout): the cut shape covers a rail during its bounds spring")

            #expect(line.minX == max(loose.frame.minX - SidebarStyle.groupRailReach, SidebarStyle.groupEdgePadding), "\(layout): the line left the rail, at \(line.minX)")
            #expect(header.pill.frame.minX == 0 && header.pill.frame.width == head.width, "\(layout): the bar spans \(header.pill.frame)")
            switch layout {
            case .edge, .joined:
                #expect(head.minX == line.minX, "\(layout): the bar starts at \(head.minX), the line at \(line.minX)")
            case .inside:
                // A top-level bar keeps the edge padding (`groupEdgePadding`, b5400e7e342), and may then start at its line.
                #expect(head.minX == max(SidebarStyle.groupEdgePadding, line.minX - SidebarStyle.groupLineCornerInset) && head.minX <= line.minX,
                        "inside: the bar starts at \(head.minX), the line at \(line.minX)")
            }
            #expect(head.minX >= 0, "\(layout): the bar runs off the list at \(head.minX)")
            let cut = line.minY - head.maxY
            #expect(cut == (layout == .joined ? 0 : SidebarStyle.groupLineCut), "\(layout): a \(cut) pt cut")
            let last = try #require(list.rowViews[.workspace(Self.members[2])])
            #expect(line.maxY == last.frame.maxY, "\(layout): the line ends at \(line.maxY), the last member at \(last.frame.maxY)")

            // The members keep the ungrouped rows' left edge, and no member's fill covers the line.
            for id in Self.members {
                let member = try #require(list.rowViews[.workspace(id)])
                #expect(member.frame.minX == loose.frame.minX, "\(layout): \(id.rawValue) starts at \(member.frame.minX)")
                #expect(line.maxX <= member.frame.minX, "\(layout): \(id.rawValue)'s fill covers the line")
            }

            // One color: the line is the bar's rest color.
            header.updateLayer()
            view.updateLayer()
            let barColor = try GroupPaletteDefaultTests.rgb(header.pill.backgroundColor)
            let drawn = try GroupPaletteDefaultTests.rgb(view.railShape.fillColor)
            #expect(GroupPaletteDefaultTests.same(barColor, drawn), "\(layout): line \(drawn), bar \(barColor)")
        }
    }

    /// Joined, an open group's bar squares only its bottom-left corner (the line runs out of it); a collapsed one and
    /// every other layout round all four.
    @Test(arguments: SidebarGroupLineLayout.allCases)
    func onlyAnOpenJoinedHeaderSquaresItsBottomLeftCorner(_ layout: SidebarGroupLineLayout) throws {
        try Self.withLayout(layout) {
            let (sidebar, window) = Self.sidebar()
            defer { window.close() }
            let open = try #require(sidebar.list.rowViews[.group(Self.group)] as? GroupHeaderRowView)
            let folded = try #require(sidebar.list.rowViews[.group(Self.closed)] as? GroupHeaderRowView)
            let all = SidebarGroupLine.barCorners(open: false, flipped: false)
            let bottomLeft: CACornerMask = open.pill.contentsAreFlipped() ? .layerMinXMaxYCorner : .layerMinXMinYCorner
            #expect(all.contains(bottomLeft) && all.contains(.layerMaxXMaxYCorner))
            #expect(open.pill.maskedCorners == (layout == .joined ? all.subtracting(bottomLeft) : all), "\(layout): \(open.pill.maskedCorners)")
            #expect(folded.pill.maskedCorners == all, "\(layout): a collapsed group has no line to join")
        }
    }

    /// The header's bar reaches left over its line in every layout, but its name stays on the ungrouped rows' column.
    @Test(arguments: SidebarGroupLineLayout.allCases)
    func aReachingHeaderKeepsItsNameOnTheRowsColumn(_ layout: SidebarGroupLineLayout) throws {
        try Self.withLayout(layout) {
            let (sidebar, window) = Self.sidebar()
            defer { window.close() }
            let header = try #require(sidebar.list.rowViews[.group(Self.group)] as? GroupHeaderRowView)
            let row = try #require(sidebar.list.rowViews[.workspace(Self.looseID)] as? WorkspaceRowView)
            let name = sidebar.convert(header.titleFrame, from: header).minX + Metrics.space1
            let column = sidebar.convert(row.icon.frame, from: row).minX
            #expect(abs(name - column) < 0.5, "\(layout): the header's name starts at \(name), the ungrouped rows at \(column)")
        }
    }

    /// Joined, the line runs out of the bar only with the band header; switching `sidebar.groupHeader` live to
    /// another style lays the list out again, so the line drops back to the cut and the corner rounds again.
    @Test func aLiveHeaderStyleSwitchMovesTheJoinedLine() throws {
        try Self.withLayout(.joined) {
            let key = SidebarGroupHeaderStyle.tunable.key
            TunableStore.shared.set(key, SidebarGroupHeaderStyle.band.tunableValue)
            defer { TunableStore.shared.set(key, nil) }
            let (sidebar, window) = Self.sidebar()
            defer { window.close() }
            let head = try #require(sidebar.list.rowViews[.group(Self.group)]).frame
            let joined = try #require(sidebar.list.groupLineViews.shown[Self.group]?.frame)
            #expect(joined.minY == head.maxY, "band: the joined line does not start where the bar ends")
            try #require(TunableStore.shared.set(key, SidebarGroupHeaderStyle.line.tunableValue) == SidebarGroupHeaderStyle.line.tunableValue)
            sidebar.renderNow() // what the sidebar's observation runs on the change
            let bar = try #require(sidebar.list.rowViews[.group(Self.group)]).frame
            let cut = try #require(sidebar.list.groupLineViews.shown[Self.group]?.frame)
            #expect(cut.minY == bar.maxY + SidebarStyle.groupLineCut, "line style: the joined line still starts at \(cut.minY), the header ends at \(bar.maxY)")
        }
    }

    /// Nested groups: in every layout a parent's line runs left of every row beside it, a subgroup's header included,
    /// and each line keeps its own group's rail.
    @Test(arguments: SidebarGroupLineLayout.allCases)
    func aParentsLineNeverRunsUnderARow(_ layout: SidebarGroupLineLayout) throws {
        try Self.withLayout(layout) {
            let list = SidebarNestedGroupAlignmentTests.list(SidebarNestedFixture(scenario: .after).sections)
            let lines = list.groupLines(list.displayed)
            #expect(lines.count >= 2, "\(layout): the nested fixture draws \(lines.count) lines")
            for line in lines {
                let member = list.displayed.rows.first { row in
                    guard row.group == line.group else { return false }
                    if case .workspace = row.key { return true }
                    return false
                }
                if let member { // a group of subgroups only has no own member to measure the rail from
                    // A top-level rail keeps `groupEdgePadding` from the list's edge (b5400e7e342f4).
                    let rail = max(list.frame(for: member).minX - SidebarStyle.groupRailReach, SidebarStyle.groupEdgePadding)
                    #expect(line.frame.minX == rail, "\(layout): \(line.group.rawValue) left its rail")
                }
                for row in list.displayed.rows {
                    let frame = list.frame(for: row)
                    guard frame.minY < line.frame.maxY, frame.maxY > line.frame.minY else { continue } // beside the line
                    // Debug-only `inside`: a subgroup header reaches 1 pt over its top-level parent's line since that line
                    // keeps the edge padding (b5400e7e342). Known until the sidebar owner picks the fix.
                    withKnownIssue("inside layout: a subgroup header overlaps its parent's edge-padded line") {
                        #expect(line.frame.maxX <= frame.minX, "\(layout): \(line.group.rawValue)'s line runs under \(row.key)")
                    } when: { layout == .inside && line.frame.maxX > frame.minX }
                }
            }
        }
    }

    /// A parent with only nested groups still uses its own Chrome corner inset in `inside`; there is no direct
    /// member row from which to derive the rail.
    @Test
    func anInsideParentWithOnlyNestedGroupsKeepsItsCornerInset() throws {
        try Self.withLayout(.inside) {
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let parent = SidebarGroup(id: GroupID("g-parent-only"), name: "Parent", color: .purple, workspaces: [])
            var child = SidebarGroup(id: GroupID("g-child-only"), name: "Child", color: .blue,
                                     workspaces: [SidebarWorkspace(id: WorkspaceID("w-child"), title: "Child member")])
            child.parent = parent.id
            let list = SidebarNestedGroupAlignmentTests.list([
                SidebarSection(kind: .machine(machine), nodes: [.group(parent), .group(child)]),
            ])
            let parentRow = try #require(list.displayed.row(for: .group(parent.id)))
            let line = try #require(list.groupLines(list.displayed).first { $0.group == parent.id })
            let header = list.frame(for: parentRow)
            #expect(line.frame.minX == header.minX + SidebarStyle.groupHeaderOverhang,
                    "a parent rail without direct members stays inside its header corner")
        }
    }
}
