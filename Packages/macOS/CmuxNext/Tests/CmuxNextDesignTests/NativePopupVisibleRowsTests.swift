import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import CmuxVisibleRows
import CmuxVisibleRowsTesting
import QuartzCore
import Testing

/// Leo 2026-11-18 (ask-1105ee4cc6): "we draw the visible area, right? Like, that's what we're supposed to do." The
/// popups' lists in the visible-rows contract: a page popup's rows (``NativePopupContent``, up to 1000 a list) and a
/// page menu's (``WebPopupRows``, up to 200), each at 100 and 10,000 rows. Each prints its `visible-rows` lines.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)))
struct NativePopupVisibleRowsTests {
    @Test func pagePopup() async throws {
        try await VisibleRowsContract.check(PagePopupRows.self)
    }

    @Test func pageMenu() async throws {
        try await VisibleRowsContract.check(PageMenuRows.self)
    }

    /// Down moves the highlight: the row that had it and the row that has it, no other, and no row made or framed.
    @Test(arguments: [100, 10_000])
    func aHighlightMoveDrawsTheTwoRowsInvolved(_ count: Int) async throws {
        let fixture = try await PagePopupRows(rows: count)
        defer { fixture.close() }
        let content = fixture.content
        #expect(content.selected == "row-0")
        _ = content.listWork.take()
        _ = content.handleKey(125)
        let work = content.listWork.take()
        print("visible-rows page popup n=\(count) highlight move: \(work)")
        #expect(content.selected == "row-1")
        #expect(work.rowsConfigured == 2 && work.rowsLaidOut == 0 && work.itemsWalked == 0)
        #expect((content.rowView(id: "row-1") as? PopupRowView)?.isHighlighted == true)
        #expect((content.rowView(id: "row-0") as? PopupRowView)?.isHighlighted == false)
    }

    /// Up from the first row wraps to the last: the list scrolls there and draws it, highlighted, and the first row
    /// leaves with the band.
    @Test(arguments: [100, 10_000])
    func arrowingPastTheBandDrawsTheSelectedRow(_ count: Int) async throws {
        let fixture = try await PagePopupRows(rows: count)
        defer { fixture.close() }
        let content = fixture.content
        _ = content.handleKey(126)
        let last = "row-\(count - 1)"
        #expect(content.selected == last)
        let view = try #require(content.mounted[last]?.view as? PopupRowView, "the selected row is drawn")
        #expect(view.isHighlighted)
        #expect(content.visibleRect.intersects(view.frame))
        #expect(content.mounted["row-0"] == nil, "the first row left with the band")
        #expect(content.rowViewsAlive <= fixture.viewportRows * 3 + 2)
    }

    /// An update keeps every unchanged row's view; the changed row gets a new one with its text.
    @Test func anUpdateKeepsTheUnchangedRowsViews() async throws {
        let fixture = try await PagePopupRows(rows: 100)
        defer { fixture.close() }
        let before = fixture.content.mounted.mapValues(\.view)
        try await fixture.changeOneItem()
        let after = fixture.content.mounted.mapValues(\.view)
        #expect(after.filter { before[$0.key] !== $0.value }.map(\.key) == ["row-2"])
        #expect((after["row-2"] as? PopupRowView)?.titleLabel.stringValue == "Changed")
    }
}

/// Lays the window out, draws it and commits, as a display frame does.
@MainActor private func drawFrame(_ window: NSWindow) {
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    CATransaction.flush()
}

/// A page popup over `rows` action rows in a 320 x 280 scroll view, as ``DeclarativePopupHost`` hosts it.
@MainActor final class PagePopupRows: VisibleRowsFixture {
    static let name = "page popup"
    let scrollView = OverlayScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 280))
    let content = NativePopupContent()
    let window: NSWindow
    var model: NativePopupModel
    var list: NativePopupContent { content }
    var clip: NSClipView { scrollView.contentView }

    init(rows: Int) async throws {
        _ = NSApplication.shared
        scrollView.contentView = PopupClipView()
        scrollView.hasVerticalScroller = true
        content.autoresizingMask = [.width]
        scrollView.documentView = content
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 280), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.orderFrontRegardless()
        model = NativePopupModel(schemaVersion: 1, id: "visible-rows", revision: 1,
                                 anchor: NativePopupAnchor(left: 0, top: 0, right: 20, bottom: 20),
                                 side: .bottom, align: .start, width: 320,
                                 rows: (0..<rows).map { NativePopupRow(id: "row-\($0)", kind: .action, label: "Row \($0)") })
        content.setFrameSize(NSSize(width: clip.bounds.width, height: 0))
        content.update(model)
        drawFrame(window)
    }

    var viewportRows: Int {
        let visible = clip.bounds
        return content.mounted.values.filter { visible.intersects($0.view.frame) }.count
    }

    /// A shown row's label changes (the page's next revision).
    func changeOneItem() async throws {
        model.revision += 1
        model.rows[2].label = "Changed"
        content.update(model)
        drawFrame(window)
    }

    /// From the middle of the list (that move is not measured), one row down.
    func scrollOneRow() async throws -> Bool {
        let maxY = max(0, content.frame.height - clip.bounds.height)
        guard maxY > 0 else { return false }
        scroll(to: min(maxY / 2, 2_000))
        _ = content.listWork.take()
        scroll(to: clip.bounds.minY + PopupStyle.standard.rowHeight)
        return true
    }

    private func scroll(to y: CGFloat) {
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
        drawFrame(window)
    }

    /// The popup 8 pt narrower.
    func resizeOneStep() async throws -> Bool {
        window.setContentSize(NSSize(width: 312, height: 280))
        drawFrame(window)
        return true
    }

    func close() { window.close() }
}

/// A page menu over `rows` items in a 320 x 280 scroll view, as ``WebPopupPanel`` hosts it.
@MainActor final class PageMenuRows: VisibleRowsFixture {
    static let name = "page menu"
    let scrollView = OverlayScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 280))
    let rows = WebPopupRows(onPick: { _ in }, onHover: { _ in })
    let window: NSWindow
    var items: [WebPopupHost.Item]
    var list: WebPopupRows { rows }
    var clip: NSClipView { scrollView.contentView }

    init(rows count: Int) async throws {
        _ = NSApplication.shared
        scrollView.contentView = PopupClipView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = rows
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 280), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.orderFrontRegardless()
        items = (0..<count).map {
            WebPopupHost.Item(id: "\($0)", label: "Item \($0)", shortcut: nil, checked: false, disabled: false, separator: false)
        }
        rows.update(items, highlighted: "0")
        drawFrame(window)
    }

    var viewportRows: Int {
        let visible = clip.bounds
        return rows.mounted.values.filter { visible.intersects($0.view.frame) }.count
    }

    /// A shown item's label changes (the page sends its menu again).
    func changeOneItem() async throws {
        items[2].label = "Changed"
        rows.update(items, highlighted: "0")
        drawFrame(window)
    }

    /// From the middle of the menu (that move is not measured), one row down.
    func scrollOneRow() async throws -> Bool {
        let maxY = max(0, rows.frame.height - clip.bounds.height)
        guard maxY > 0 else { return false }
        scroll(to: min(maxY / 2, 2_000))
        _ = rows.listWork.take()
        scroll(to: clip.bounds.minY + PopupStyle.standard.rowHeight)
        return true
    }

    private func scroll(to y: CGFloat) {
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
        drawFrame(window)
    }

    /// The menu 8 pt narrower.
    func resizeOneStep() async throws -> Bool {
        window.setContentSize(NSSize(width: 312, height: 280))
        drawFrame(window)
        return true
    }

    func close() { window.close() }
}
