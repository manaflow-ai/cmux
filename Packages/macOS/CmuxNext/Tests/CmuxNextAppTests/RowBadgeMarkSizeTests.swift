import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-11-01, on a sidebar row's small red warning: "and every icon is still f***ing small".
/// The red warning grew to a 14 pt box (cmux#30236); the spinner and the needs-you marks beside it
/// stayed at 10 pt. Every non-dot mark now draws in one 14 pt box on the cell's center, so a row's
/// mark reads at one size on one column whatever its state; the blue unread dot keeps its token.
@MainActor @Suite struct RowBadgeMarkSizeTests {
    private static func glyph(_ state: StatusIndicatorState) throws -> (frame: CGRect, cell: CGPoint) {
        // Pinned: under the system's Reduce Motion (some CI Macs) done draws a check disc, not the dot.
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let view = RowBadgeView(frame: NSRect(x: 0, y: 0, width: 60, height: 18))
        view.configure([state], look: .corner)
        view.layoutSubtreeIfNeeded()
        let frame = try #require(view.glyphFrames.first)
        let cellY = ((view.bounds.height - view.cellSide) / 2).rounded()
        return (frame, CGPoint(x: view.cellSide / 2, y: cellY + view.cellSide / 2))
    }

    @Test(arguments: [StatusIndicatorState.working, .busy, .error, .waiting(kind: .permission), .waiting(kind: .auth)])
    func everyMarkDrawsAtTheWarningsSize(state: StatusIndicatorState) throws {
        let (frame, cell) = try Self.glyph(state)
        #expect(frame.width == RowBadgeView.markSide && frame.height == RowBadgeView.markSide, "\(state): \(frame)")
        #expect(abs(frame.midX - cell.x) < 0.01 && abs(frame.midY - cell.y) < 0.01, "\(state) is off the column")
        #expect(frame.minX == frame.minX.rounded() && frame.minY == frame.minY.rounded(), "off the pixel grid: \(frame)")
    }

    @Test func theSpinnerMatchesTheWarning() throws {
        let spinner = try Self.glyph(.working).frame, warning = try Self.glyph(.error).frame
        #expect(spinner == warning)
    }

    @Test func theUnreadDotKeepsItsToken() throws {
        let (frame, cell) = try Self.glyph(.success)
        #expect(frame.width < RowBadgeView.markSide)
        #expect(abs(frame.midX - cell.x) < 0.01 && abs(frame.midY - cell.y) < 0.01)
    }
}
