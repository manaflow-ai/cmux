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

    /// The group's members' line view, nil when none draws (the joined bar draws its own).
    private static func lineView(_ sidebar: SidebarView) -> GroupLineView? {
        GroupPaletteDefaultTests.views(GroupLineView.self, in: sidebar).first
    }

    /// The header's bar layer, the bar's rect, and the last member row, in the sidebar's coordinates.
    private static func parts(_ sidebar: SidebarView, name: String = "") throws -> (layer: CALayer, bar: CGRect, lastRow: CGRect) {
        let header = try Self.header(sidebar)
        let layer = header.barLayer
        #expect(header.barFrame.height > Metrics.dividerThickness * 4, "name \"\(name)\": a \(header.barFrame.height) pt bar is a hairline")
        let last = try #require(sidebar.list.rowViews[.workspace(Self.measured)], "no last member row")
        return (layer, sidebar.convert(header.barFrame, from: header), sidebar.convert(last.bounds, from: last))
    }

    /// Whether a shape's outline covers a point, in its layer's coordinates.
    private static func covers(_ path: CGPath?, _ x: CGFloat, _ y: CGFloat) -> Bool { path?.contains(CGPoint(x: x, y: y)) ?? false }

    /// Leo 2026-10-19, measured on his Chrome reference at 2x: by default a 26 pt header bar with
    /// 6 pt corners, a 6 pt cut (`SidebarStyle.groupLineCut`), then a 2 pt line in the bar's color
    /// whose right edge meets the end of the bar's corner arc (bar left + corner radius), that runs to
    /// the last member row's bottom. Its ends are trimmed as Chrome's are: the left corners square,
    /// the right corners cut by a quarter circle as wide as the line. An unnamed group's header is
    /// the same solid bar.
    @Test(arguments: [false, true], ["cmux-next app", ""])
    func theMembersLineStartsACutBelowTheBar(minimal: Bool, name: String) throws {
        let sidebar = Self.sidebar(minimal: minimal, name: name)
        let (layer, bar, lastRow) = try Self.parts(sidebar, name: name)
        let line = try #require(Self.lineView(sidebar), "no members' line")
        line.layoutSubtreeIfNeeded()
        line.updateLayer()
        let drawn = sidebar.convert(line.bounds, from: line)
        try #require(sidebar.isFlipped)
        #expect(SidebarStyle.groupLineCut == Metrics.space3, "Chrome's cut is about 6 pt, the space3 step")
        #expect(abs(drawn.minY - bar.maxY - SidebarStyle.groupLineCut) < 0.01,
                "minimal \(minimal): a \(drawn.minY - bar.maxY) pt gap below the bar, want the \(SidebarStyle.groupLineCut) pt cut")
        #expect(abs(drawn.width - Metrics.space1) < 0.01, "a \(drawn.width) pt line, want Chrome's \(Metrics.space1) pt one")
        #expect(abs(layer.cornerRadius - Metrics.space3) < 0.51, "a \(layer.cornerRadius) pt bar corner, Chrome's is about 6 pt")
        #expect(abs(drawn.maxX - (bar.minX + layer.cornerRadius)) < 0.01,
                "the line's right edge \(drawn.maxX) is not where the bar's corner arc ends (\(bar.minX + layer.cornerRadius))")
        #expect(abs(drawn.maxY - lastRow.maxY) < 0.01, "the line ends at \(drawn.maxY), the last member row at \(lastRow.maxY)")
        #expect(layer.mask == nil && layer.maskedCorners.roundedCount == 4, "the default bar rounds every corner")
        // Chrome's trim, in the line's own coordinates.
        let shape = (line.layer?.mask as? CAShapeLayer)?.path, w = drawn.width, h = drawn.height, e: CGFloat = 0.15
        #expect(Self.covers(shape, e, e) && Self.covers(shape, e, h - e), "the line's left corners are not square")
        #expect(!Self.covers(shape, w - e, e) && !Self.covers(shape, w - e, h - e), "the line's right corners are not trimmed")
        #expect(Self.covers(shape, w / 2, h / 2) && Self.covers(shape, w - e, h / 2), "the line's body is not solid")
    }

    /// `sidebar.groupLineJoinsHeader` (off by default), Leo 2026-10-19: "you join it properly and
    /// you square off the thing". The bar draws bar and line as ONE shape (one layer, one outline):
    /// the line runs straight down from the bar's square bottom-left corner at the bar's own left
    /// edge, at full width, with no cap, step or seam at the join, to the last member row's bottom,
    /// where it ends in the same trim as the default line. No separate line view draws.
    @Test(arguments: [false, true], ["cmux-next app", ""])
    func theJoinSettingDrawsBarAndLineAsOneShape(minimal: Bool, name: String) throws {
        let sidebar = Self.sidebar(minimal: minimal, name: name, joined: true)
        let (layer, bar, lastRow) = try Self.parts(sidebar, name: name)
        #expect(Self.lineView(sidebar) == nil, "a separate line view draws beside the joined bar")
        let header = try Self.header(sidebar)
        let shapeFrame = sidebar.convert(layer.frame, from: header)
        try #require(sidebar.isFlipped)
        #expect(abs(shapeFrame.minX - bar.minX) < 0.01 && abs(shapeFrame.minY - bar.minY) < 0.01, "the shape \(shapeFrame) does not start at the bar \(bar)")
        #expect(abs(shapeFrame.maxY - lastRow.maxY) < 0.01, "the shape ends at \(shapeFrame.maxY), the last member row at \(lastRow.maxY)")
        let shape = try #require((layer.mask as? CAShapeLayer)?.path, "the joined bar has no outline")
        let b = bar.height, w = Metrics.space1, end = shapeFrame.height, r = Metrics.space3, e: CGFloat = 0.15
        #expect(!Self.covers(shape, e, e) && !Self.covers(shape, bar.width - e, e) && !Self.covers(shape, bar.width - e, b - e),
                "the bar's other corners are not round")
        #expect(Self.covers(shape, e, b - e) && Self.covers(shape, e, b + e), "the corner over the line is not square")
        for y in stride(from: b - 1, through: end - w - e, by: 0.5) {
            #expect(Self.covers(shape, e, y) && Self.covers(shape, w - e, y), "the line is not full width at \(y) pt")
            #expect(!Self.covers(shape, w + e, max(y, b + e)), "the line is wider than \(w) pt at \(y) pt")
        }
        #expect(Self.covers(shape, e, end - e) && !Self.covers(shape, w - e, end - e), "the line's end is not trimmed as Chrome's")
        #expect(!Self.covers(shape, r + e, b + 1), "the shape fills past the line under the bar")
    }

    /// Turning the setting on or off redraws an open sidebar, without a relaunch: the render
    /// reloads the list (Reduce Motion, so it lands in this turn).
    @Test func turningTheJoinOnAndOffRedrawsTheGroup() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let sidebar = Self.sidebar(minimal: false)
        #expect(Self.lineView(sidebar) != nil && Self.lineView(sidebar)?.isHidden == false, "the default draws a line view")
        for joined in [true, false] {
            sidebar.design.sidebarSections.groupLineJoinsHeader = joined
            sidebar.renderNow()
            sidebar.layoutSubtreeIfNeeded()
            #expect(sidebar.list.groupLineJoinsHeader == joined, "the list did not get the setting \(joined)")
            let (layer, _, _) = try Self.parts(sidebar)
            #expect((layer.mask != nil) == joined, "joined \(joined): the bar's outline")
            #expect((Self.lineView(sidebar) != nil) == !joined, "joined \(joined): the line view")
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
