import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import CmuxVisibleRows
import CmuxVisibleRowsTesting
import QuartzCore
import Testing

/// Leo 2026-11-18 (ask-1105ee4cc6): "we draw the visible area, right? Like, that's what we're supposed to do." The
/// popups' lists in the visible-rows contract, run against the base code (base proof: this branch is never merged).
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)))
struct NativePopupVisibleRowsTests {
    @Test func pagePopup() async throws {
        try await VisibleRowsContract.check(PagePopupRows.self)
    }

    @Test func pageMenu() async throws {
        try await VisibleRowsContract.check(PageMenuRows.self)
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
        return content.rowViews.filter { visible.intersects($0.1.frame) }.count
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
        return rows.subviews.filter { visible.intersects($0.frame) }.count
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
