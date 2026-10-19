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

    /// Leo 2026-10-19: Chrome's tab groups. By default the members' line starts a small,
    /// deliberate cut below the header bar; an unnamed group's header is the same solid bar.
    @Test(arguments: [false, true], ["cmux-next app", ""])
    func theMembersLineStartsACutBelowTheBar(minimal: Bool, name: String) throws {
        let sidebar = Self.sidebar(minimal: minimal, name: name)
        let (overlap, drawn, bar) = try Self.overlap(sidebar, name: name)
        #expect(abs(-overlap - SidebarStyle.groupLineCut) < 0.01,
                "minimal \(minimal): a \(-overlap) pt gap between the bar and its members' line, want the \(SidebarStyle.groupLineCut) pt cut")
        #expect(drawn.minX >= bar.minX && drawn.maxX <= bar.maxX, "the line \(drawn) is not under the bar \(bar)")
    }

    /// `sidebar.groupLineJoinsHeader` (off by default): the line joins the bar as one shape,
    /// no gap; only its round top end tucks into the bar, so the bar's rounded corner shows no seam.
    @Test(arguments: [false, true], ["cmux-next app", ""])
    func theJoinSettingRunsTheLineIntoTheBar(minimal: Bool, name: String) throws {
        let sidebar = Self.sidebar(minimal: minimal, name: name, joined: true)
        let (overlap, drawn, bar) = try Self.overlap(sidebar, name: name)
        #expect(overlap >= 0, "minimal \(minimal): a \(-overlap) pt gap between the bar and its members' line")
        #expect(overlap <= drawn.width / 2 + 0.01, "minimal \(minimal): the line runs \(overlap) pt into the bar")
        #expect(drawn.minX >= bar.minX && drawn.maxX <= bar.maxX, "the line \(drawn) is not under the bar \(bar)")
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
