import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import CmuxVisibleRows
import CmuxVisibleRowsTesting
import QuartzCore
import Testing

/// Leo 2026-11-18 (ask-1105ee4cc6): "we draw the visible area, right? Like, that's what we're supposed to do." The
/// page popup's two other layouts in the visible-rows contract, each at 100 and 10,000 rows: the columns (the model
/// picker: a harness rail column beside a models column that scrolls on its own) and a placed rail (harness tabs
/// beside the list). Each prints its `visible-rows` lines.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)))
struct NativePopupLayoutVisibleRowsTests {
    @Test func pagePopupColumns() async throws {
        try await VisibleRowsContract.check(PagePopupColumnsRows.self)
    }

    @Test func pagePopupPlacedRail() async throws {
        try await VisibleRowsContract.check(PagePopupPlacedRailRows.self)
    }

    /// Down in a long column moves the highlight on two rows; arrowing past the band scrolls the column there and
    /// draws the row, and the column's first rows leave with the band.
    @Test(arguments: [100, 10_000])
    func arrowsInALongColumnDrawOnlyItsBand(_ count: Int) async throws {
        let fixture = try await PagePopupColumnsRows(rows: count)
        defer { fixture.close() }
        let content = fixture.content
        #expect(content.selected == "m-0")
        _ = content.listWork.take()
        _ = content.handleKey(125)
        let work = content.listWork.take()
        #expect(content.selected == "m-1")
        #expect(work.rowsConfigured == 2 && work.rowsLaidOut == 0 && work.itemsWalked == 0, "\(work)")
        for _ in 0..<40 { _ = content.handleKey(125) }
        let view = try #require(content.mounted["m-41"]?.view as? PopupRowView, "the highlighted row is drawn")
        #expect(view.isHighlighted && view.isDescendant(of: fixture.column.document))
        #expect(fixture.column.documentVisibleRect.intersects(view.frame), "its column scrolled to it")
        #expect(content.mounted["m-0"] == nil, "the column's first rows left with its band")
        #expect(content.rowViewsAlive <= fixture.viewportRows * 3)
    }

    /// An update keeps every unchanged row's view in its new column, and the row with the keys keeps them.
    @Test func anUpdateKeepsTheColumnsUnchangedRows() async throws {
        let fixture = try await PagePopupColumnsRows(rows: 100)
        defer { fixture.close() }
        let before = fixture.content.mounted.filter { $0.key.hasPrefix("m-") }.mapValues(\.view)
        try await fixture.changeOneItem()
        let after = fixture.content.mounted.filter { $0.key.hasPrefix("m-") }.mapValues(\.view)
        #expect(after.filter { before[$0.key] !== $0.value }.map(\.key) == ["m-2"])
        #expect(after.values.allSatisfy { $0.isDescendant(of: fixture.column.document) }, "kept rows moved into the new column")
    }
}

/// Lays the window out, draws it and commits, as a display frame does.
@MainActor private func drawFrame(_ window: NSWindow) {
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    CATransaction.flush()
}

/// A page popup's content in a scroll view in a window, as ``DeclarativePopupHost`` hosts it.
@MainActor final class PagePopupHarness {
    let scrollView = OverlayScrollView(frame: NSRect(x: 0, y: 0, width: 350, height: 400))
    let content = NativePopupContent()
    let window: NSWindow
    var model: NativePopupModel

    init(_ model: NativePopupModel) {
        _ = NSApplication.shared
        self.model = model
        scrollView.contentView = PopupClipView()
        scrollView.hasVerticalScroller = true
        content.autoresizingMask = [.width]
        scrollView.documentView = content
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 350, height: 400), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.orderFrontRegardless()
        content.setFrameSize(NSSize(width: scrollView.contentView.bounds.width, height: 0))
        content.update(model)
        drawFrame(window)
    }

    func update(_ change: (inout NativePopupModel) -> Void) {
        model.revision += 1
        change(&model)
        content.update(model)
        drawFrame(window)
    }

    /// Scrolls `scroll` to the middle of its document (not measured), then one row down.
    func scrollOneRow(_ scroll: NSScrollView) -> Bool {
        let clip = scroll.contentView
        let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
        guard maxY > 0 else { return false }
        move(scroll, to: min(maxY / 2, 2_000))
        _ = content.listWork.take()
        move(scroll, to: clip.bounds.minY + PopupStyle.standard.rowHeight)
        return true
    }

    private func move(_ scroll: NSScrollView, to y: CGFloat) {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        drawFrame(window)
    }

    /// Rows and tabs drawn inside `visible` of `document`.
    func shown(in document: NSView, _ visible: NSRect) -> Int {
        content.mounted.values.filter { $0.view.superview === document && visible.intersects($0.view.frame) }.count
    }

    func resizeOneStep() {
        window.setContentSize(NSSize(width: 342, height: 400))
        drawFrame(window)
    }

    func close() { window.close() }
}

/// The model picker's columns: a harness rail of 3 tabs beside a models column of `rows`, under the search row.
@MainActor final class PagePopupColumnsRows: VisibleRowsFixture {
    static let name = "page popup columns"
    let harness: PagePopupHarness
    var list: NativePopupContent { harness.content }
    var content: NativePopupContent { harness.content }
    var column: NativePopupColumnView { harness.content.columnViews[1] }

    init(rows: Int) async throws {
        let rail = NativePopupColumn(id: "rail", label: "Harness", width: 48, rail: true, rows: [
            NativePopupRow(id: "claude", kind: .action, label: "Claude", checked: true, monogram: "C"),
            NativePopupRow(id: "codex", kind: .action, label: "Codex", monogram: "X"),
            NativePopupRow(id: "add", kind: .action, label: "Add", monogram: "+"),
        ])
        let models = NativePopupColumn(id: "models", label: "Model",
                                       rows: (0..<rows).map { NativePopupRow(id: "m-\($0)", kind: .action, label: "Model \($0)") })
        harness = PagePopupHarness(NativePopupModel(schemaVersion: 1, id: "picker", revision: 1,
                                                    anchor: NativePopupAnchor(left: 0, top: 0, right: 20, bottom: 20),
                                                    side: .bottom, align: .start, width: 350, rows: [],
                                                    search: NativePopupField(id: "query", value: "", placeholder: "Search"),
                                                    columns: [rail, models], columnsHeight: 220))
    }

    /// Both columns' rows on screen: the rail's tabs and the models in view.
    var viewportRows: Int {
        content.columnViews.reduce(0) { $0 + harness.shown(in: $1.document, $1.documentVisibleRect) }
    }

    /// A shown model's label changes (the page's next revision).
    func changeOneItem() async throws {
        harness.update { $0.columns?[1].rows[2].label = "Changed" }
    }

    /// The models column scrolls on its own, one row.
    func scrollOneRow() async throws -> Bool { harness.scrollOneRow(column) }

    /// The popup 8 pt narrower: the models column (the flexible one) narrows.
    func resizeOneStep() async throws -> Bool {
        harness.resizeOneStep()
        return true
    }

    func close() { harness.close() }
}

/// A placed rail: 3 harness tabs down the left beside a list of `rows`, which the popup scrolls.
@MainActor final class PagePopupPlacedRailRows: VisibleRowsFixture {
    static let name = "page popup placed rail"
    let harness: PagePopupHarness
    var list: NativePopupContent { harness.content }

    init(rows: Int) async throws {
        harness = PagePopupHarness(NativePopupModel(schemaVersion: 1, id: "placed", revision: 1,
                                                    anchor: NativePopupAnchor(left: 0, top: 0, right: 20, bottom: 20),
                                                    side: .bottom, align: .start, width: 350,
                                                    rows: (0..<rows).map { NativePopupRow(id: "r-\($0)", kind: .action, label: "Row \($0)") },
                                                    rail: [NativePopupRow(id: "claude", kind: .action, label: "Claude", checked: true, monogram: "C"),
                                                           NativePopupRow(id: "codex", kind: .action, label: "Codex", monogram: "X"),
                                                           NativePopupRow(id: "add", kind: .action, label: "Add", monogram: "+")],
                                                    railPlacement: .left))
    }

    var viewportRows: Int { harness.shown(in: harness.content, harness.scrollView.documentVisibleRect) }

    func changeOneItem() async throws {
        harness.update { $0.rows[2].label = "Changed" }
    }

    func scrollOneRow() async throws -> Bool { harness.scrollOneRow(harness.scrollView) }

    func resizeOneStep() async throws -> Bool {
        harness.resizeOneStep()
        return true
    }

    func close() { harness.close() }
}
