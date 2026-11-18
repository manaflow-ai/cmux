import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import SwiftUI
import Testing

/// The row ids a list reported as it drew (`EnvironmentValues.rowDrawn`).
@MainActor private final class Draws {
    var ids: [String] = []

    /// The ids drawn since the last take, then forgets them.
    func take() -> [String] {
        defer { ids = [] }
        return ids
    }
}

/// Leo 2026-11-18: "we draw the visible area, right?" The Todo page holds at most 50 items
/// (`MAX_CHECKLIST_ITEMS`, cmux-tui/crates/cmux-tui-core/src/state/workspace_checklist_store.rs), so
/// its list is not windowed, but a change draws only the rows it changed: a key typed in the add
/// field draws none, one item's new text draws that row, an edit begun draws the edited row. Each
/// run prints its counts ("todo-row-counts").
@MainActor @Suite(.serialized, .closesItsWindows) struct WorkspaceTodoRowCountTests {
    /// Lets SwiftUI apply what changed, then lays the page out.
    static func settle(_ view: NSView) {
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            view.layoutSubtreeIfNeeded()
        }
    }

    /// The item ids `change` drew, in draw order.
    fileprivate static func drawn(_ view: NSView, _ probe: Draws, _ change: () -> Void) -> [String] {
        _ = probe.take()
        change()
        settle(view)
        return probe.take()
    }

    @Test(arguments: [10, 50])
    func aChangeDrawsOnlyTheRowsItChanged(count: Int) throws {
        _ = NSApplication.shared
        let store = try WorkspaceChecklistTests.store()
        let workspace = try #require(store.workspace(id: "w1"))
        workspace.checklist = (0..<count).map { WorkspaceChecklistItem(id: "rc\(count)-\($0)", text: "item \($0)") }
        let model = WorkspaceTodoPageModel(workspaceID: "w1", workspace: { store.workspace(id: $0) }, perform: { _, _ in })
        let probe = Draws()
        let host = NSHostingView(rootView: WorkspaceTodoPageView(model: model).environment(\.rowDrawn) { probe.ids.append($0) })
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 2_400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 2_400)
        window.orderFrontRegardless()

        let mounted = Set(Self.drawn(host, probe) { Self.settle(host) }).count
        let typed = Self.drawn(host, probe) { model.draft = "a" }
        let changed = Self.drawn(host, probe) { workspace.checklist[3].text = "item 3, changed" }
        let editing = Self.drawn(host, probe) { model.editing = "rc\(count)-5" }
        print("todo-row-counts n=\(count) mounted=\(mounted) typed=\(typed.count) item_change=\(changed.count) "
            + "begin_edit=\(editing.count)")

        #expect(mounted == count, "the page shows every item (at most 50), drew \(mounted)")
        #expect(typed.isEmpty, "a key in the add field drew \(typed.count) rows")
        #expect(Set(changed) == ["rc\(count)-3"], "one item's new text drew \(changed.count) rows: \(changed.prefix(8))")
        #expect(Set(editing) == ["rc\(count)-5"], "an edit begun drew \(editing.count) rows: \(editing.prefix(8))")
    }
}
