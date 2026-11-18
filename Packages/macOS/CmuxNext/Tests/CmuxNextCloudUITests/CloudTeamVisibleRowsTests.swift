import AppKit
@testable import CmuxNextCloudUI
import CmuxNextDesign
import CmuxVisibleRows
import CmuxVisibleRowsTesting
import QuartzCore
import Testing

/// Leo 2026-11-18 (ask-1105ee4cc6): "we draw the visible area, right?" The sidebar's Team section registered with
/// the visible-rows contract, at 100 and 10,000 sessions.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)))
struct CloudTeamVisibleRowsTests {
    @Test func teamSessions() async throws {
        try await VisibleRowsContract.check(CloudTeamSectionRows.self)
    }
}

/// The Team section over `rows` sessions the store listed, in a window as tall as the section gets (`maxRows`).
@MainActor final class CloudTeamSectionRows: VisibleRowsFixture {
    typealias Fixture = CloudTeamSessionStoreTests
    static let name = "cloud team sessions"
    static let width: CGFloat = 240
    let store: CloudTeamSessionStore
    let view: CloudTeamHostingView
    let window: NSWindow
    var list: CloudTeamSectionView { view.section }
    var clip: NSClipView { view.section.scroll.contentView }

    init(rows: Int) async throws {
        _ = NSApplication.shared
        let worker = Fixture.FakeWorker()
        store = CloudTeamSessionStore(transport: worker.transport, activeTeam: { Fixture.team })
        let listed = Fixture.list((0..<rows).map { Fixture.row("vr\($0)", at: rows - $0) })
        // The select's list, the section's own first list and its members read: every list answers the same rows.
        worker.replies = Array(repeating: .success(listed), count: 8)
        await store.select(.team)
        view = CloudTeamHostingView(store: store, tokens: { ThemeScope.app.tokens }, perform: { _, _ in }, open: { _ in })
        let height = CloudTeamSectionView.filterHeight + CloudTeamSectionView.rowHeight * CGFloat(CloudTeamSectionView.maxRows)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: Self.width, height: height), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        await settle()
        drawFrame()
    }

    /// Lets the section's observations and its first list run.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(200))
    }

    private func drawFrame() {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    var viewportRows: Int {
        let visible = clip.bounds
        return list.rows.filter { visible.intersects($0.frame) }.count
    }

    /// A shown session's title changes, as a live update puts the row in the store.
    func changeOneItem() async throws {
        var row = try #require(store.sessions.dropFirst(2).first)
        row.title = "changed"
        store.apply(row)
        await settle()
        drawFrame()
        #expect(list.rows.contains { $0.titleText == "changed" }, "the section shows the change")
    }

    /// From the middle of the list (that move is not measured), one row down.
    func scrollOneRow() async throws -> Bool {
        let maxY = max(0, CloudTeamSectionView.rowHeight * CGFloat(store.sessions.count) - clip.bounds.height)
        guard maxY > 0 else { return false }
        scroll(to: min(maxY / 2, 2_000))
        _ = list.listWork.take()
        scroll(to: clip.bounds.minY + CloudTeamSectionView.rowHeight)
        return true
    }

    private func scroll(to y: CGFloat) {
        clip.scroll(to: NSPoint(x: 0, y: y))
        list.scroll.reflectScrolledClipView(clip)
        drawFrame()
    }

    /// One live-resize step of the sidebar: 8 pt narrower.
    func resizeOneStep() async throws -> Bool {
        window.setContentSize(NSSize(width: Self.width - 8, height: window.frame.height))
        drawFrame()
        return true
    }

    func close() { window.close() }
}
