import AppKit
import CmuxNextTestSupport
import CmuxVisibleRows
import CmuxVisibleRowsTesting
import Foundation
import QuartzCore
import Testing
@testable import CmuxNextAgentPane

/// Leo (2026-11-18): "we draw the visible area, right? Like, that's what we're supposed to do." Session
/// Info's list in the visible-rows contract at 100 and 10,000 rows, and a repeated model (a clock tick
/// that changes nothing) doing no row work.
@Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)))
@MainActor
struct AgentPaneSessionInfoCountTests {
    @Test func visibleRows() async throws {
        try await VisibleRowsContract.check(SessionInfoRows.self)
    }

    @Test(arguments: [100, 10_000])
    func aRepeatedModelDoesNoRowWork(rows count: Int) async throws {
        let f = try await SessionInfoRows(rows: count)
        defer { f.close() }
        let alive = f.list.subviews.count
        _ = f.list.listWork.take()
        f.store.update(try SessionInfoRows.model(rows: count))
        f.draw()
        let work = f.list.listWork.take()
        print("session-info-counts rows=\(count) alive=\(alive) repeat=\(work)")
        #expect(work.rowsConfigured == 0)
        #expect(work.rowsLaidOut == 0)
        #expect(f.list.subviews.count == alive)
    }
}

/// Session Info's list: one section of `rows` file rows in a 320 x 600 panel.
@MainActor final class SessionInfoRows: VisibleRowsFixture {
    static let name = "session info"
    let store = AgentPaneSessionInfoStore()
    let panel: AgentPaneSessionInfoPanel
    let content: AgentPaneSessionInfoContent
    let window: NSWindow
    let rows: Int
    var list: SessionInfoListView { content.rows }
    var clip: NSClipView { content.scrollView.contentView }

    static func model(rows count: Int, changed: Int? = nil) throws -> AgentPaneSessionInfoModel {
        let rows: [[String: Any]] = (0..<count).map { index in
            ["id": "r\(index)", "title": "row \(index)", "action": "changes.open:\(index)",
             "trailing": index == changed ? "+2" : "+1"]
        }
        let info: [String: Any] = [
            "open": true, "width": 320, "top": 28, "side": 0, "label": "Session Info",
            "sections": [["id": "changes", "group": "made", "title": "Changes", "meta": "\(count)",
                          "open": true, "foldable": true, "rows": rows]],
        ]
        return try #require(AgentPaneSessionInfoModel.decode(info))
    }

    init(rows: Int) async throws {
        _ = NSApplication.shared
        self.rows = rows
        panel = AgentPaneSessionInfoPanel(store: store)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 600), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = panel
        panel.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
        window.orderFrontRegardless()
        store.update(try Self.model(rows: rows))
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        content = try #require(all(panel).compactMap { $0 as? AgentPaneSessionInfoContent }.first)
        draw()
    }

    func draw() {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    var viewportRows: Int {
        let visible = clip.bounds
        return content.lines.filter { $0.line.kind == .row && visible.intersects($0.frame) }.count
    }

    /// A shown row's count changes (a file's +1 becomes +2), as the page sends it: the whole model again.
    func changeOneItem() async throws {
        store.update(try Self.model(rows: rows, changed: 3))
        draw()
    }

    /// From the middle of the list (that move is not measured), one row down.
    func scrollOneRow() async throws -> Bool {
        let maxY = max(0, list.frame.height - clip.bounds.height)
        guard maxY > 0 else { return false }
        scroll(to: min(maxY / 2, 2_000))
        _ = list.listWork.take()
        scroll(to: clip.bounds.minY + SessionInfoMetrics.rowHeight)
        return true
    }

    private func scroll(to y: CGFloat) {
        clip.scroll(to: NSPoint(x: 0, y: y))
        content.scrollView.reflectScrolledClipView(clip)
        draw()
    }

    /// The panel's edge dragged 8 pt wider.
    func resizeOneStep() async throws -> Bool {
        panel.frame.size.width += 8
        draw()
        return true
    }

    func close() { window.close() }
}
