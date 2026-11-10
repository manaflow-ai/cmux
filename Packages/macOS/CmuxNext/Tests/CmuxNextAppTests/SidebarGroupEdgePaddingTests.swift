import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-25 (msg 12385): "groups headers and rails need more left padding". A top-level group
/// header's bar started at x = 0 and its rail 2 pt in, flush with the sidebar's edge. The rule: at every
/// sidebar density, Minimal Mode and nesting level, a header bar and its rail keep at least
/// `groupEdgePadding` (the row gap less the rail and its gap, `rowEdgeGap - groupRailReach`, floored at 0) of padding
/// from the list's left edge, while member rows keep the ungrouped rows' left edge (#23975).
///
/// Since Lawrence 2026-11-09 ("left/right should have same padding as top") the row gap is `Metrics.space1` (2 pt), less
/// than the rail's 4 pt reach, so the padding is 0 at the default spacing: a top-level bar and rail start on the list's
/// edge. The 2 / 4 pt padding of 2026-10-25 no longer fits left of the members' fills.
@MainActor @Suite(.serialized) struct SidebarGroupEdgePaddingTests {
    @Test(arguments: SidebarGroupRailAlignmentTests.cases)
    func headersAndRailsKeepLeftPadding(_ c: SidebarGroupRailAlignmentTests.Case) throws {
        try SidebarGroupRailAlignmentTests.with(c.density, c.minimal) {
            // 63d46f831c0a kept the rail gap from member fills; the old contract put the rail flush against them.
            let want = SidebarStyle.groupEdgePadding
            #expect(want == max(0, SidebarStyle.rowEdgeGap - SidebarStyle.groupRailReach))
            #expect(want == 0, "\(c.testDescription): a 2 pt row gap leaves no room left of a 4 pt rail reach")
            let (list, window) = SidebarGroupRailAlignmentTests.list(SidebarNestedFixture(scenario: c.scenario))
            defer { window.close() }
            let lines = list.groupLines(list.displayed)
            #expect(!lines.isEmpty, "\(c.testDescription): no rails drawn")
            var minBar = CGFloat.greatestFiniteMagnitude, minRail = CGFloat.greatestFiniteMagnitude
            for line in lines {
                let header = try #require(list.rowViews[.group(line.group)] as? GroupHeaderRowView)
                minBar = min(minBar, list.convert(header.leadingMarkFrame, from: header).minX)
                minRail = min(minRail, line.frame.minX)
            }
            print("EDGEPAD|\(c.testDescription)|bar \(minBar)|rail \(minRail)|want \(want)")
            #expect(minBar >= want - 0.01, "\(c.testDescription): header bar starts \(minBar) pt from the edge, want >= \(want)")
            #expect(minRail >= want - 0.01, "\(c.testDescription): rail starts \(minRail) pt from the edge, want >= \(want)")
        }
    }
}
