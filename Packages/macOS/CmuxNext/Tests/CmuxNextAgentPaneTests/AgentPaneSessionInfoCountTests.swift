import AppKit
import CmuxNextTestSupport
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Leo (2026-11-18): "we draw the visible area, right? Like, that's what we're supposed to do." Session
/// Info's list at 100 and 10,000 rows: it mounts the rows in view and one viewport each side, a changed
/// row configures that row alone and moves no other, a repeated model and a scroll step touch only what
/// they must, and a new width measures only the mounted rows. Each run prints its counts
/// ("session-info-counts").
@Suite(.serialized, .closesItsWindows)
@MainActor
struct AgentPaneSessionInfoCountTests {
    private static let height: CGFloat = 600

    private static func info(rows count: Int, changed: Int? = nil) -> [String: Any] {
        let rows: [[String: Any]] = (0..<count).map { index in
            ["id": "r\(index)", "title": "row \(index)", "action": "changes.open:\(index)",
             "trailing": index == changed ? "+2" : "+1"]
        }
        return [
            "open": true, "width": 320, "top": 28, "side": 0, "label": "Session Info",
            "sections": [["id": "changes", "group": "made", "title": "Changes", "meta": "\(count)",
                          "open": true, "foldable": true, "rows": rows]],
        ]
    }

    @Test(arguments: [100, 10_000])
    func theListDrawsWhatIsInViewAndTouchesOnlyWhatChanged(rows count: Int) throws {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let store = AgentPaneSessionInfoStore()
        let panel = AgentPaneSessionInfoPanel(store: store)
        panel.frame = CGRect(x: 0, y: 0, width: 320, height: Self.height)
        store.update(try #require(AgentPaneSessionInfoModel.decode(Self.info(rows: count))))
        panel.layoutSubtreeIfNeeded()
        let content = try #require(all(panel).compactMap { $0 as? AgentPaneSessionInfoContent }.first)
        let scroll = try #require(all(panel).compactMap { $0 as? NSScrollView }.first)
        let viewport = scroll.contentSize.height
        // The rows in view and one viewport each side, at any length.
        let bound = Int((3 * viewport / SessionInfoMetrics.rowHeight).rounded(.up)) + 2
        let alive = content.lines.count
        #expect(content.lines.first?.line.title == "Changes")

        // One row's value changes: that row configures, no other row is added, moved or measured.
        content.counts = SessionInfoListCounts()
        store.update(try #require(AgentPaneSessionInfoModel.decode(Self.info(rows: count, changed: 3))))
        let change = (configured: content.counts.configured, mounted: content.counts.mounted,
                      laidOut: content.counts.laidOut, measured: content.counts.measured)
        #expect(content.lines.first { $0.line.id == "row:changes:r3" }?.line.trailing == "+2")

        // The same model again (a clock tick that changes nothing): no work.
        content.counts = SessionInfoListCounts()
        store.update(try #require(AgentPaneSessionInfoModel.decode(Self.info(rows: count, changed: 3))))
        let repeated = content.counts.configured + content.counts.mounted + content.counts.laidOut

        // One scroll step of three rows: only the rows it reveals are made.
        content.counts = SessionInfoListCounts()
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 3 * SessionInfoMetrics.rowHeight))
        scroll.reflectScrolledClipView(scroll.contentView)
        let step = (configured: content.counts.configured, mounted: content.counts.mounted)
        let afterScroll = content.lines.count

        // A new width: only the mounted rows are measured, once.
        content.counts = SessionInfoListCounts()
        panel.frame.size.width = 300
        panel.layoutSubtreeIfNeeded()
        let widthMeasured = content.counts.measured
        let widthConfigured = content.counts.configured

        print("session-info-counts rows=\(count) alive=\(alive) bound=\(bound) change.configured=\(change.configured) change.mounted=\(change.mounted) change.laidOut=\(change.laidOut) change.measured=\(change.measured) repeat=\(repeated) scroll.configured=\(step.configured) scroll.mounted=\(step.mounted) scroll.alive=\(afterScroll) width.measured=\(widthMeasured) width.configured=\(widthConfigured)")
        #expect(alive <= bound)
        #expect(afterScroll <= bound)
        #expect(change.configured == 1)
        #expect(change.mounted == 0)
        #expect(change.laidOut == 0)
        #expect(change.measured <= 1)
        #expect(repeated == 0)
        #expect(step.configured <= 4)
        #expect(step.mounted == step.configured)
        #expect(widthMeasured <= afterScroll)
        #expect(widthConfigured == 0)
    }
}
