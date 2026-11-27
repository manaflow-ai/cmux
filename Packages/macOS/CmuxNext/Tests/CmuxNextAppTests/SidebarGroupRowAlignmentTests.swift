import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Lawrence 2026-10-30 (NIGHTLY, "Sleep alarm" group): "alignment here is bad". The group's rail sat flush against its
/// member row's fill (the header's edge padding ate the rail's gap), and the rail began part way down the first member
/// row (its 6 pt cut ran past the 2.5 pt gap between the rows). Lawrence 2026-10-30 (msg 18582): "triangle not aligned,
/// not sure if triangle is even centered": a usage-warning triangle on a row with no spinner sat right of the spinners'
/// column, in a smaller box.
///
/// One geometry, at every density and text size: the header bar, the rail and the members' block share one left edge
/// and one right edge, the rail keeps its gap from every row beside it and spans exactly its members, the header's
/// name keeps the members' text column, and every trailing status mark (spinner or triangle) shares one center and box.
@MainActor @Suite(.serialized) struct SidebarGroupRowAlignmentTests {
    nonisolated struct Case: CustomTestStringConvertible, Sendable {
        var density: SidebarDensity
        var textSize: SidebarTextSize
        var testDescription: String { "\(density.rawValue)/text-\(textSize.rawValue)" }
    }

    nonisolated static let cases: [Case] = SidebarTextSize.allCases.flatMap { textSize in
        SidebarDensity.allCases.map { Case(density: $0, textSize: textSize) }
    }

    @Test(arguments: cases)
    func theRailKeepsItsGapAndSpansItsMembers(_ c: Case) throws {
        try SidebarGroupRailAlignmentTests.with(c.density, .off, textSize: c.textSize) {
            let (sidebar, window) = SidebarGroupLineLayoutTests.sidebar()
            defer { window.close() }
            let list = sidebar.list
            let header = try #require(list.rowViews[.group(SidebarGroupLineLayoutTests.group)] as? GroupHeaderRowView)
            let line = try #require(list.groupLineViews.shown[SidebarGroupLineLayoutTests.group]?.frame, "\(c): no rail")
            let members = try SidebarGroupLineLayoutTests.members.map { try #require(list.rowViews[.workspace($0)]) }
            let bar = list.convert(header.leadingMarkFrame, from: header)
            // One left edge: the bar's and the rail's.
            #expect(bar.minX == line.minX, "\(c): bar at \(bar.minX), rail at \(line.minX)")
            // One right edge: the bar's and every member's.
            for member in members {
                #expect(member.frame.maxX == header.frame.maxX, "\(c): member ends at \(member.frame.maxX), header at \(header.frame.maxX)")
                // The rail never touches a member's fill: its own gap (`Metrics.space1`) stays.
                #expect(line.maxX + Metrics.space1 <= member.frame.minX,
                        "\(c): rail ends at \(line.maxX), member fill starts at \(member.frame.minX)")
            }
            // The rail spans its members: it starts at the first member's top, never part way down it.
            let first = try #require(members.first), last = try #require(members.last)
            #expect(line.minY == first.frame.minY, "\(c): rail starts at \(line.minY), first member at \(first.frame.minY)")
            #expect(line.maxY == last.frame.maxY, "\(c): rail ends at \(line.maxY), last member at \(last.frame.maxY)")
            // The bar keeps some room from the list's edge.
            #expect(bar.minX > 0, "\(c): the bar sits flush on the list's edge")
        }
    }

    /// The header's name keeps its members' text column (no step between the header's text and theirs).
    @Test(arguments: cases)
    func theHeaderNameSitsOnTheMembersTextColumn(_ c: Case) throws {
        try SidebarGroupRailAlignmentTests.with(c.density, .off, textSize: c.textSize) {
            let (sidebar, window) = SidebarGroupLineLayoutTests.sidebar()
            defer { window.close() }
            let list = sidebar.list
            let header = try #require(list.rowViews[.group(SidebarGroupLineLayoutTests.group)] as? GroupHeaderRowView)
            let member = try #require(list.rowViews[.workspace(SidebarGroupLineLayoutTests.members[0])] as? WorkspaceRowView)
            let name = list.convert(header.titleFrame, from: header).minX
            let title = list.convert(member.titleFrame, from: member).minX
            #expect(abs(name - title) < 0.5, "\(c): header name at \(name), member title at \(title)")
        }
    }

    /// A row's warning triangle with no spinner sits on the spinners' column, in the spinner's box: the frame
    /// `layoutColumnMark` gives a spinner (`statusGlyphFrame` centered on `trailingColumnCenterX`, on the row's middle).
    @Test(arguments: SidebarDensity.allCases)
    func theWarningTriangleSharesTheSpinnersCenterAndBox(_ density: SidebarDensity) throws {
        try SidebarGroupRailAlignmentTests.with(density, .off) {
            var warned = SidebarWorkspace(id: WorkspaceID("ws-warned"), title: "warned", lastActivity: Date(), kind: .harness)
            warned.usageWarnings = ["90 subagents started in the last hour, above 40"]
            let row = try SidebarUsageWarningTests.rowView(warned)
            row.layoutSubtreeIfNeeded()
            try #require(!row.usageWarningMark.isHidden, "the warned row shows its triangle")
            let triangle = row.usageWarningMark.frame
            let side = SidebarStyle.statusGlyphSize
            let spinner = row.statusGlyphFrame(trailing: SidebarStyle.trailingColumnCenterX(rowWidth: row.bounds.width) + side / 2,
                                               centerY: triangle.midY)
            #expect(abs(triangle.midX - spinner.midX) < 0.5, "\(density.rawValue): triangle center x \(triangle.midX), spinner column \(spinner.midX)")
            #expect(triangle.size == spinner.size, "\(density.rawValue): triangle box \(triangle.size), spinner box \(spinner.size)")
            #expect(abs(triangle.midY - row.bounds.midY) < 0.5, "\(density.rawValue): triangle center y \(triangle.midY), row middle \(row.bounds.midY)")
        }
    }
}
