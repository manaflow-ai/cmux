import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-11-03: "symbol size discrepancy groups vs workspaces". A group header drew its roll-up (the red warning,
/// the spinner) in the 10 pt indicator box and scaled it by the indicator scale setting, while the workspace rows under
/// it drew the warning in a 14 pt box and the spinner at the status glyph size, both at a fixed scale. Both row kinds now
/// read one token per state (`SidebarStyle.statusMarkSide(for:)`), centered on the one trailing column.
@MainActor @Suite(.serialized) struct SidebarStatusGlyphParityTests {
    private static let width: CGFloat = 240
    private static let height: CGFloat = 24

    /// A group header showing `state` as its roll-up, laid out at rest (no hover), so the mark is on the column.
    private static func header(_ state: StatusIndicatorState) -> GroupHeaderRowView {
        Motion.reduceMotionOverride = true // the reveal slot sets its frame at once
        defer { Motion.reduceMotionOverride = nil }
        let id = GroupID("grp-glyph-parity")
        let header = GroupHeaderRowView(key: .group(id))
        header.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let group = CmuxNextSidebar.SidebarGroup(id: id, name: "parity", color: .blue, workspaces: [])
        let row = SidebarRow(key: .group(id), y: 0, height: height, section: .pinned, group: id, siblingIndex: 0,
                             parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: 0, groupColor: nil)
        header.configure(group, row: row, status: state, animated: false)
        header.needsLayout = true
        header.layoutSubtreeIfNeeded()
        return header
    }

    /// The glyph a workspace row's badge draws for `state` (`WorkspaceRowView+Badges` puts this view on the column).
    private static func rowGlyph(_ state: StatusIndicatorState) throws -> CGRect {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let badge = RowBadgeView(frame: NSRect(x: 0, y: 0, width: 60, height: 18))
        badge.configure([state], look: .plain)
        badge.layoutSubtreeIfNeeded()
        return try #require(badge.glyphFrames.first)
    }

    @Test(arguments: [StatusIndicatorState.error, .working, .busy, .waiting(kind: .permission)])
    func aGroupHeaderAndAWorkspaceRowDrawOneMarkSize(state: StatusIndicatorState) throws {
        let header = Self.header(state)
        let mark = header.debugActivityFrame
        let row = try Self.rowGlyph(state)
        #expect(mark.width == row.width && mark.height == row.height,
                "\(state): the header draws \(mark.size), a workspace row \(row.size)")
        #expect(mark.width == SidebarStyle.statusMarkSide(for: state), "\(state): \(mark)")
        #expect(header.debugActivityIgnoresScale, "the header's mark follows the scale setting; the rows' do not")
        // One column centre for both row kinds (`SidebarColumns.trailingCenter`, where a row's badge centers).
        let column = SidebarStyle.columns(rowWidth: Self.width).trailingCenter()
        #expect(abs(mark.midX - column) <= 0.5, "\(state): the header's mark centers at \(mark.midX), the rows' column at \(column)")
        #expect(abs(mark.midY - Self.height / 2) <= 0.5, "\(state): \(mark)")
    }

    @Test func theWarningIsLargerThanTheSpinnerInBothRowKinds() {
        #expect(SidebarStyle.statusMarkSide(for: .error) == RowBadgeView.markSide)
        #expect(SidebarStyle.statusMarkSide(for: .working) == RowBadgeView.spinnerSide)
        #expect(RowBadgeView.spinnerSide < RowBadgeView.markSide)
    }
}
