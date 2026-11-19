import AppKit
@testable import CmuxNextApp
import CmuxNextChiefMemory
@testable import CmuxNextCloudUI
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTestSupport
import CmuxVisibleRows
import CmuxVisibleRowsTesting
import Foundation
import QuartzCore
import SwiftUI
import Testing

/// Leo 2026-11-18 (ask-1105ee4cc6): "we draw the visible area, right?" Three lazy SwiftUI lists: the Automations list
/// and the Memory Inspector's view list under the visible-rows contract at 100 and 10,000 rows, and what a change in
/// each page configures: a new selection the old and the new row, a key press none, the same selection again none.
/// The Todo page holds at most 50 items (`MAX_CHECKLIST_ITEMS`, cmux-tui/crates/cmux-tui-core/src/state/
/// workspace_checklist_store.rs), so it is not windowed and is measured for rule 2 only. Each run prints its counts.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)))
struct SwiftUIListsVisibleRowsTests {
    @Test func automationsList() async throws {
        try await VisibleRowsContract.check(AutomationsListRows.self)
    }

    @Test func memoryInspector() async throws {
        try await VisibleRowsContract.check(MemoryInspectorLines.self)
    }

    @Test(arguments: [100, 10_000])
    func anAutomationsSelectionConfiguresTwoRowsAndSortsNothing(rows: Int) async throws {
        let fixture = try await AutomationsListRows(rows: rows)
        defer { fixture.close() }
        let page = fixture.page
        _ = page.listWork.take()
        let sorts = page.sectionBuilds
        page.selection = page.rows[1].id
        await showFrames(fixture.window)
        let selected = page.listWork.take()
        page.selection = page.rows[1].id
        await showFrames(fixture.window)
        let again = page.listWork.take()
        print("swiftui-lists automations n=\(rows) select=\(selected) reselect=\(again) sorts=\(page.sectionBuilds - sorts)")
        #expect(selected.rowsConfigured == 2, "a new selection configured \(selected.rowsConfigured) rows: the old and the new row only")
        #expect(selected.itemsWalked == 0 && page.sectionBuilds == sorts, "a new selection walked \(selected.itemsWalked) rows")
        #expect(again.rowsConfigured == 0, "the same selection again configured \(again.rowsConfigured) rows")
    }

    @Test(arguments: [100, 10_000])
    func aMemoryLineOpenedConfiguresTwoRowsAndAKeyNone(rows: Int) async throws {
        let fixture = try await MemoryInspectorLines(rows: rows)
        defer { fixture.close() }
        let model = fixture.model
        await model.open(MemorySource.name(rows - 1))
        await showFrames(fixture.window)
        _ = model.listWork.take()
        await model.open(MemorySource.name(rows - 2))
        await showFrames(fixture.window)
        let opened = model.listWork.take()
        model.query = "a"
        await showFrames(fixture.window)
        let typed = model.listWork.take()
        print("swiftui-lists memory n=\(rows) open=\(opened) typed=\(typed)")
        #expect(opened.rowsConfigured == 2, "opening a line configured \(opened.rowsConfigured) rows: the line left and the line opened")
        #expect(typed.rowsConfigured == 0, "a key in the search field configured \(typed.rowsConfigured) rows")
    }

    /// What the baselined "items walked" costs at 10,000 rows: one Automations reload (both sources parsed, indexed,
    /// grouped and sorted) and one Memory Inspector reload (the whole view decoded), each the median of 7, no window.
    /// Printed ("swiftui-lists walk"), not asserted: the number is for the row-patch follow-up.
    @Test func theBaselinedWalksAtTenThousandRows() async throws {
        let rows = 10_000
        func median(_ run: () async -> Void) async -> Int {
            var samples: [Duration] = []
            for _ in 0..<7 {
                let start = ContinuousClock.now
                await run()
                samples.append(ContinuousClock.now - start)
            }
            let mid = samples.sorted()[samples.count / 2]
            return Int(mid.components.seconds * 1_000_000 + mid.components.attoseconds / 1_000_000_000_000)
        }
        let local = await AutomationsSource(count: rows).json() // made once: the timed reload times the app, not this fake
        let page = AutomationsPage(local: { local }, cloud: { Data(#"{"automations": []}"#.utf8) })
        let automations = await median {
            await page.reload(now: AutomationsSource.now)
            _ = page.sections(now: AutomationsSource.now)
        }
        let model = ChiefMemoryInspectorModel(source: MemorySource(count: rows), confirmDelete: { _, _ in true })
        let memory = await median { await model.reload() }
        print("swiftui-lists walk n=\(rows) automations_reload_us=\(automations) memory_reload_us=\(memory)")
        #expect(page.rows.count == rows && model.lines.count == rows)
    }

    @Test(arguments: [10, 50])
    func aTodoChangeConfiguresOnlyTheRowItChanged(items: Int) async throws {
        _ = NSApplication.shared
        let store = try WorkspaceChecklistTests.store()
        let workspace = try #require(store.workspace(id: "w1"))
        workspace.checklist = (0..<items).map { WorkspaceChecklistItem(id: "vr-\($0)", text: "item \($0)") }
        let model = WorkspaceTodoPageModel(workspaceID: "w1", workspace: { store.workspace(id: $0) }, perform: { _, _ in })
        let window = hostWindow(NSHostingView(rootView: WorkspaceTodoPageView(model: model)), width: 640, height: 2_400)
        defer { window.close() }
        await showFrames(window)
        let mounted = model.listWork.take()
        model.draft = "a"
        await showFrames(window)
        let typed = model.listWork.take()
        workspace.checklist[3].text = "item 3, changed"
        await showFrames(window)
        let changed = model.listWork.take()
        model.editing = "vr-5"
        await showFrames(window)
        let editing = model.listWork.take()
        print("swiftui-lists todo n=\(items) mount=\(mounted) typed=\(typed) item_change=\(changed) begin_edit=\(editing)")
        #expect(typed.rowsConfigured == 0, "a key in the add field configured \(typed.rowsConfigured) rows")
        #expect(changed.rowsConfigured == 1, "one item's new text configured \(changed.rowsConfigured) rows")
        #expect(editing.rowsConfigured == 1, "an edit begun configured \(editing.rowsConfigured) rows")
    }
}

/// A borderless window of `width` x `height` showing `content`.
@MainActor private func hostWindow(_ content: NSView, width: CGFloat, height: CGFloat) -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = content
    content.frame = NSRect(x: 0, y: 0, width: width, height: height)
    window.orderFrontRegardless()
    return window
}

/// Lets SwiftUI apply what changed, then lays the window out, draws it and commits, a few frames.
@MainActor private func showFrames(_ window: NSWindow) async {
    for _ in 0..<4 {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(40))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }
}

/// The leftmost scroll view in `window` (a page's list column).
@MainActor private func listScrollView(in window: NSWindow) -> NSScrollView? {
    func all(_ view: NSView) -> [NSScrollView] {
        if let scroll = view as? NSScrollView { return [scroll] }
        return view.subviews.flatMap(all)
    }
    return window.contentView.map(all)?.min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
}

/// What a SwiftUI list fixture reads from its list's scroll view: rows in the viewport and one row of scroll, a row's
/// height being the list's height over its rows (the rows are one design each).
@MainActor private struct ListScroll {
    let window: NSWindow
    let rows: Int

    var scroll: NSScrollView? { listScrollView(in: window) }
    var rowHeight: CGFloat { max(20, (scroll?.documentView?.frame.height ?? 0) / CGFloat(max(rows, 1))) }
    var viewportRows: Int { Int(((scroll?.contentView.bounds.height ?? 0) / rowHeight).rounded(.up)) }

    /// From the middle of the list (not measured: `reset` takes its work), one row down.
    func scrollOneRow(reset: () -> Void) async -> Bool {
        guard let scroll, let document = scroll.documentView else { return false }
        let clip = scroll.contentView
        let maxY = max(0, document.frame.height - clip.bounds.height)
        guard maxY > 0 else { return false }
        await move(scroll, to: min(maxY / 2, 2_000))
        reset()
        await move(scroll, to: clip.bounds.minY + rowHeight)
        return true
    }

    private func move(_ scroll: NSScrollView, to y: CGFloat) async {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        await showFrames(window)
    }
}

/// This Mac's `cmux automation list --json` for `count` enabled automations, one renamed on demand.
private actor AutomationsSource {
    nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)
    let count: Int
    var renamed: Int?

    init(count: Int) { self.count = count }

    func rename(_ index: Int) { renamed = index }

    func json() -> Data {
        let rows = (0..<count).map { i in
            #"{"id": "auto_vr\#(i)", "name": "\#(i == renamed ? "Renamed" : "Automation") \#(i)", "enabled": true, "#
                + #""trigger": {"type": "every", "seconds": 1800}, "body": {"type": "prompt", "prompt": "task \#(i)"}, "#
                + #""next_run_at": \#(Self.now.timeIntervalSince1970 + 172_800 + Double(i)), "last_run": {"state": "succeeded"}}"#
        }
        return Data((#"{"automations": ["# + rows.joined(separator: ",") + "]}").utf8)
    }
}

/// The Automations page over `rows` automations, every one under Later in next-run order, in a 900 x 600 window.
@MainActor final class AutomationsListRows: VisibleRowsFixture {
    static let name = "automations list"
    fileprivate let source: AutomationsSource
    let page: AutomationsPage
    let window: NSWindow
    private let reader: ListScroll
    var list: AutomationsPage { page }

    init(rows: Int) async throws {
        let source = AutomationsSource(count: rows)
        self.source = source
        page = AutomationsPage(local: { await source.json() }, cloud: { Data(#"{"automations": []}"#.utf8) })
        await page.reload(now: AutomationsSource.now)
        let view = AutomationsPageView(page: page, palette: AutomationsPalette(tokens: ThemeScope.app.tokens), now: AutomationsSource.now)
        window = hostWindow(NSHostingView(rootView: view), width: 900, height: 600)
        reader = ListScroll(window: window, rows: rows)
        await showFrames(window)
    }

    var viewportRows: Int { reader.viewportRows }

    /// A shown automation is renamed: the sources answer again and the page reloads, as its refresh does.
    func changeOneItem() async throws {
        await source.rename(2)
        await page.reload(now: AutomationsSource.now)
        await showFrames(window)
    }

    func scrollOneRow() async throws -> Bool {
        await reader.scrollOneRow { _ = page.listWork.take() }
    }

    /// The list column is a fixed 320 points wide (`AutomationsPageView.list`).
    func resizeOneStep() async throws -> Bool { false }

    func close() { window.close() }
}

/// A Chief whose view has `count` lines, `vr-<i>`, oldest first; one line's text changes on demand.
private actor MemorySource: ChiefMemorySource {
    let count: Int
    var changed: Int?
    /// The last `/api/view` answer, made again only after a change (so a timed reload times the app, not this fake).
    var view: Data?

    init(count: Int) { self.count = count }

    nonisolated static func name(_ index: Int) -> String { "vr-\(index)" }

    func change(_ index: Int) {
        changed = index
        view = nil
    }

    func call(_ path: String, query: [String: String]) async throws(ChiefMemoryError) -> Data {
        switch path {
        case "/api/status": return Data(#"{"messages": 64, "nodes_built": 127, "stale": [], "editable": true}"#.utf8)
        case "/api/memory/changes": return Data(#"{"changes": [], "stale": []}"#.utf8)
        case "/api/node":
            return Data((#"{"name": "4+1", "level": 0, "start": 4, "n": 1, "built": true, "text": "user: hello", "#
                + #""message": {"id": 4, "kind": "user", "text": "hello there", "bytes": 11}}"#).utf8)
        case "/api/view":
            if let view { return view }
            let lines = (0..<count).map { i in
                #"{"name": "\#(Self.name(i))", "level": 1, "start": \#(i), "n": 1, "built": true, "#
                    + #""text": "\#(i == changed ? "changed" : "line") \#(i)"}"#
            }
            let made = Data((#"{"lines": ["# + lines.joined(separator: ",") + "]}").utf8)
            view = made
            return made
        default: throw .refused(status: 404, message: "no API \(path)")
        }
    }
}

/// The Memory Inspector over a view of `rows` lines (newest on top) in a 900 x 600 window.
@MainActor final class MemoryInspectorLines: VisibleRowsFixture {
    static let name = "memory inspector"
    fileprivate let source: MemorySource
    let model: ChiefMemoryInspectorModel
    let window: NSWindow
    private let reader: ListScroll
    var list: ChiefMemoryInspectorModel { model }

    init(rows: Int) async throws {
        let source = MemorySource(count: rows)
        self.source = source
        model = ChiefMemoryInspectorModel(source: source, confirmDelete: { _, _ in true })
        await model.reload()
        window = hostWindow(NSHostingView(rootView: ChiefMemoryInspectorView(model: model)), width: 900, height: 600)
        reader = ListScroll(window: window, rows: rows)
        await showFrames(window) // the view's own reload on appear
        await showFrames(window)
    }

    var viewportRows: Int { reader.viewportRows }

    /// The second line from the top is rebuilt with new text: the inspector reads the view again, as after a change.
    func changeOneItem() async throws {
        await source.change(reader.rows - 2)
        await model.reload()
        await showFrames(window)
    }

    func scrollOneRow() async throws -> Bool {
        await reader.scrollOneRow { _ = model.listWork.take() }
    }

    /// The rows are SwiftUI views SwiftUI lays out; the meter counts no layout, so a width step has nothing to read.
    func resizeOneStep() async throws -> Bool { false }

    func close() { window.close() }
}
