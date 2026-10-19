import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-18 (screen recording of the NIGHTLY sidebar): "There are weird horizontal
/// bars everywhere here, and we also lost the group UI where it's a solid background color."
/// With Minimal Mode on, every group header had become its name beside a hairline (#19936), and
/// every busy workspace drew a full-width indeterminate line under its title. A group header is
/// one solid bar in its color with Minimal Mode on or off, and a busy row with no measured
/// progress draws no line.
@MainActor @Suite(.serialized) struct SidebarGroupSolidHeaderTests {
    private static let group = GroupID("grp-solid")
    private static let busy = WorkspaceID("ws-busy")
    private static let measured = WorkspaceID("ws-measured")

    private static func sidebar(minimal: Bool, name: String = "cmux-next app", joined: Bool = false) -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let busy = SidebarWorkspace(id: busy, title: "sidebar", activity: .working(progress: nil),
                                    progress: SidebarProgress(value: nil))
        let measured = SidebarWorkspace(id: measured, title: "build", activity: .busy(progress: 0.5),
                                        progress: SidebarProgress(value: 0.5))
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .group(SidebarGroup(id: group, name: name, color: .blue, workspaces: [busy, measured])),
            ]),
        ])
        let design = DesignSettings()
        design.sidebarSections.minimal = minimal
        design.sidebarSections.groupLineJoinsHeader = joined
        let sidebar = SidebarView(model: model, design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        // The settings reach the list on an observation a turn later; draw them in this turn.
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }

    private static func header(_ sidebar: SidebarView) throws -> GroupHeaderRowView {
        let header = try #require(sidebar.list.rowViews[.group(group)] as? GroupHeaderRowView)
        header.layoutSubtreeIfNeeded()
        header.updateLayer()
        return header
    }

    @Test(arguments: [false, true])
    func aGroupHeaderIsOneSolidBarInItsColor(minimal: Bool) throws {
        let sidebar = Self.sidebar(minimal: minimal)
        // Minimal Mode is on when asked: the header row is shorter than the standard one.
        let row = try #require(sidebar.list.displayed.row(for: .group(Self.group)))
        #expect((row.height < SidebarLayoutMetrics.standard.groupHeaderHeight) == minimal, "minimal \(minimal), header \(row.height) pt")
        let header = try Self.header(sidebar)
        // The bar is the header's full-width rounded layer (as `SidebarGroupChromeLookTests` reads it).
        let bar = try #require(header.layer?.sublayers?.first { !$0.isHidden && $0.frame.width >= header.bounds.width - 0.5 && $0.cornerRadius > 0 },
                               "no full-width rounded bar: the header draws a hairline")
        #expect(bar.frame.height > Metrics.dividerThickness * 4, "a \(bar.frame.height) pt bar is a hairline, not a group bar")
        let fill = try #require(bar.backgroundColor.flatMap { NSColor(cgColor: $0) })
        #expect(fill.alphaComponent > 0.5, "the bar's fill is see-through (\(fill.alphaComponent))")
    }

    /// How far the members' line runs into the header bar: negative is a gap between them.
    private static func overlap(_ sidebar: SidebarView, name: String) throws -> (overlap: CGFloat, line: CGRect, bar: CGRect) {
        let header = try Self.header(sidebar)
        let bar = try #require(header.layer?.sublayers?.first { !$0.isHidden && $0.frame.width >= header.bounds.width - 0.5 && $0.cornerRadius > 0 },
                               "name \"\(name)\": no full-width rounded bar")
        #expect(bar.frame.height > Metrics.dividerThickness * 4, "name \"\(name)\": a \(bar.frame.height) pt bar is a hairline")
        let line = try #require(GroupPaletteDefaultTests.views(GroupLineView.self, in: sidebar).first, "no members' line")
        line.layoutSubtreeIfNeeded()
        line.updateLayer()
        let barRect = sidebar.convert(bar.frame, from: header)
        let drawn = sidebar.convert(line.bounds, from: line)
        // The bar's edge nearest the members, in a flipped sidebar or not.
        let overlap = sidebar.isFlipped ? barRect.maxY - drawn.minY : drawn.maxY - barRect.minY
        return (overlap, drawn, barRect)
    }

    /// The header bar's layer and the last member row, in the sidebar's coordinates.
    private static func parts(_ sidebar: SidebarView) throws -> (bar: CALayer, lastRow: CGRect) {
        let header = try Self.header(sidebar)
        let bar = try #require(header.layer?.sublayers?.first { !$0.isHidden && $0.frame.width >= header.bounds.width - 0.5 && $0.cornerRadius > 0 })
        let last = try #require(sidebar.list.rowViews[.workspace(Self.measured)], "no last member row")
        return (bar, sidebar.convert(last.bounds, from: last))
    }

    /// The bar's corner that meets the members' line: its bottom-left one, in the layer's own
    /// coordinates (flipped or not).
    private static func bottomLeft(_ sidebar: SidebarView) throws -> CACornerMask {
        try #require(Self.header(sidebar).layer).contentsAreFlipped() ? .layerMinXMaxYCorner : .layerMinXMinYCorner
    }

    /// Leo 2026-10-19, his Chrome reference: by default a 26 pt header bar with 6 pt round
    /// corners, then a small cut (`SidebarStyle.groupLineCut`), then a thin line in the bar's
    /// color, round at both ends, inset a little inside the bar's left edge (`groupBarX`), that
    /// runs to the last member row's bottom. An unnamed group's header is the same solid bar.
    @Test(arguments: [false, true], ["cmux-next app", ""])
    func theMembersLineStartsACutBelowTheBar(minimal: Bool, name: String) throws {
        let sidebar = Self.sidebar(minimal: minimal, name: name)
        let (overlap, drawn, bar) = try Self.overlap(sidebar, name: name)
        #expect(abs(-overlap - SidebarStyle.groupLineCut) < 0.01,
                "minimal \(minimal): a \(-overlap) pt gap between the bar and its members' line, want the \(SidebarStyle.groupLineCut) pt cut")
        #expect(SidebarStyle.groupLineCut == Metrics.space3, "Chrome's cut is about 6 pt, the space3 step")
        #expect(abs(drawn.minX - bar.minX - SidebarStyle.groupBarX) < 0.01, "the line \(drawn) is not \(SidebarStyle.groupBarX) pt inside the bar \(bar)")
        #expect(abs(drawn.width - Metrics.space1) < 0.01, "a \(drawn.width) pt line, want Chrome's thin \(Metrics.space1) pt one")
        let (layer, lastRow) = try Self.parts(sidebar)
        let lineEnd = sidebar.isFlipped ? drawn.maxY : drawn.minY, rowEnd = sidebar.isFlipped ? lastRow.maxY : lastRow.minY
        #expect(abs(lineEnd - rowEnd) < 0.01, "the line ends at \(lineEnd), the last member row at \(rowEnd)")
        #expect(layer.maskedCorners == [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner],
                "the default bar rounds every corner")
        #expect(abs(layer.cornerRadius - Metrics.space3) < 0.51, "a \(layer.cornerRadius) pt bar corner, Chrome's is about 6 pt")
    }

    /// `sidebar.groupLineJoinsHeader` (off by default), Leo 2026-10-19 "all lined up on the left":
    /// the line's left edge is flush with the bar's left edge and meets the bar with no gap, and the
    /// bar's bottom-left corner is square there, so bar and line are one L shape.
    @Test(arguments: [false, true], ["cmux-next app", ""])
    func theJoinSettingRunsTheLineIntoTheBar(minimal: Bool, name: String) throws {
        let sidebar = Self.sidebar(minimal: minimal, name: name, joined: true)
        let (overlap, drawn, bar) = try Self.overlap(sidebar, name: name)
        #expect(overlap >= 0, "minimal \(minimal): a \(-overlap) pt gap between the bar and its members' line")
        #expect(overlap <= drawn.width + 0.01, "minimal \(minimal): the line runs \(overlap) pt into the bar")
        #expect(abs(drawn.minX - bar.minX) < 0.01, "the line \(drawn) is not flush with the bar's left edge \(bar)")
        let (layer, _) = try Self.parts(sidebar)
        #expect(!layer.maskedCorners.contains(try Self.bottomLeft(sidebar)), "the bar's corner over the line is still round")
        #expect(layer.maskedCorners.roundedCount == 3, "only the corner over the line is square: \(layer.maskedCorners)")
    }

    /// Turning the setting on or off moves an open sidebar's lines, without a relaunch: the
    /// render reloads the list (Reduce Motion, so the move lands in this turn).
    @Test func turningTheJoinOnAndOffMovesTheLine() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let sidebar = Self.sidebar(minimal: false)
        #expect(try Self.overlap(sidebar, name: "").overlap < 0, "the default has no cut")
        for joined in [true, false] {
            sidebar.design.sidebarSections.groupLineJoinsHeader = joined
            sidebar.renderNow()
            #expect(sidebar.list.groupLineJoinsHeader == joined, "the list did not get the setting \(joined)")
            sidebar.layoutSubtreeIfNeeded()
            let overlap = try Self.overlap(sidebar, name: "").overlap
            if joined {
                #expect(overlap >= 0, "turning the join on left a \(-overlap) pt cut")
            } else {
                #expect(abs(overlap + SidebarStyle.groupLineCut) < 0.01, "turning the join off left the line \(overlap) pt into the bar")
            }
        }
    }

    /// VoiceOver reads an unnamed group's header as a group, not ", 2 workspaces".
    @Test func anUnnamedGroupHeaderReadsAsAGroup() throws {
        let header = try Self.header(Self.sidebar(minimal: false, name: ""))
        let label = try #require(header.accessibilityLabel())
        #expect(!label.hasPrefix(","), "VoiceOver reads \"\(label)\"")
        #expect(label.hasPrefix(Strings.unnamedGroup), "VoiceOver reads \"\(label)\"")
    }

    /// The line's top end tucks into the bar, so the bar must draw over it: a header the list
    /// adds after the line exists (scrolled back into view, re-applied, a drag look) goes in
    /// where every row does, right above the decorations, and must still cover the line.
    @Test func aHeaderAddedAfterItsLineStillDrawsOverIt() throws {
        let sidebar = Self.sidebar(minimal: false)
        let list = sidebar.list
        let header = try Self.header(sidebar)
        let line = try #require(GroupPaletteDefaultTests.views(GroupLineView.self, in: list).first, "no members' line")
        header.removeFromSuperview()
        list.addSubview(header, positioned: .above, relativeTo: list.decorations)
        let order = list.subviews
        let headerIndex = try #require(order.firstIndex(of: header)), lineIndex = try #require(order.firstIndex(of: line))
        #expect(lineIndex < headerIndex, "the members' line draws over its header bar")
    }

    @Test(arguments: [false, true])
    func aBusyRowWithoutMeasuredProgressDrawsNoLine(minimal: Bool) throws {
        let sidebar = Self.sidebar(minimal: minimal)
        let busy = try #require(sidebar.list.rowViews[.workspace(Self.busy)] as? WorkspaceRowView)
        #expect(busy.progress == nil)
        #expect(busy.progressTrack.isHidden)
        let measured = try #require(sidebar.list.rowViews[.workspace(Self.measured)] as? WorkspaceRowView)
        #expect(measured.progress?.value == 0.5)
    }

    @Test func aConnectingPlaceholderKeepsItsIndeterminateBar() {
        let ws = SidebarWorkspace(id: WorkspaceID("ws-ssh"), title: "", progress: SidebarProgress(value: nil), rowState: .placeholder)
        #expect(WorkspaceRowContent.bar(ws) != nil)
    }
}

private extension CACornerMask {
    /// How many corners the mask rounds.
    var roundedCount: Int {
        [CACornerMask.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner].filter(contains).count
    }
}
