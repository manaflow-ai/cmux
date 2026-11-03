import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Foundation
import Testing

/// R3b end to end (Lawrence 2026-10-31: "creating new columns must never resize existing
/// columns"; cmux-ad 08:06Z scope). Real keys through the window's key router (Ctrl-Cmd-X New
/// Column, Cmd-D Split Right) and the registry's action path, against a same-tree cmux-tui, in the
/// real window. After each create has settled (3 s: cmux-ad saw a column go from 732 to 286 pt
/// 1.5 s after the second New Column key), every column that was there keeps its width in points in
/// the window's layout and in the daemon; the new column is new space. Cmd-D splits the focused
/// pane inside its own column: no other column changes width. Covers the first column beside a
/// single pane, the second new column, Cmd-D in a column, New Column and New Column Left under
/// fitScreen, and a column beside a zoomed pane, under `layout.newColumnWidth` fixed (the default).
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)),
                  .enabled(if: NSScreen.main != nil, "real keys and window frames need a screen: run on a GUI host"),
                  .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewColumnKeepsWidthJourneyTests {
    /// How a create is started: a key through the key router, or an action run at a pane.
    enum Start {
        case key(String, NSEvent.ModifierFlags, keyCode: UInt16)
        case action(ActionID)
    }

    static let newColumnKey = Start.key("x", [.control, .command], keyCode: 7)
    static let cmdD = Start.key("d", [.command], keyCode: 2)

    @Test func newColumnsNeverResizeTheColumnsThere() async throws {
        try await PinnedPageTests.withApp { services, _ in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            window.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 760), display: true)
            window.makeKeyAndOrderFront(nil)
            let id = try await services.windows.createWorkspace(WorkspaceSpawn(), into: controller.state.id)
            try await PinnedPageTests.until({ Self.shown(controller, workspace: id).count == 1 }, report: { Self.describe(controller) })
            let content = try #require(controller.workspaceContent)
            content.layoutModel.newColumnWidthModeOverride = .fixed
            content.layoutModel.defaultColumnWidthOverride = 2.0 / 3.0
            let a = try #require(Self.shown(controller, workspace: id).first)
            content.focus.send(.focusPane(a.paneKey, source: .programmatic))

            // Ctrl-Cmd-X beside the workspace's only pane, then again from the new column it focused.
            try await Self.create(Self.newColumnKey, at: nil, controller, workspace: id, expecting: 2, what: "Ctrl-Cmd-X beside one pane")
            try await Self.create(Self.newColumnKey, at: nil, controller, workspace: id, expecting: 3, what: "the second Ctrl-Cmd-X")
            // Cmd-D splits the focused pane inside its own column: no other column changes width.
            try await Self.create(Self.cmdD, at: nil, controller, workspace: id, expecting: 4, what: "Cmd-D in a column", splitsColumn: true)
            // The action path under fitScreen, right and left of a column.
            content.layoutModel.newColumnWidthModeOverride = .fitScreen
            try await Self.create(.action("newColumn"), at: a, controller, workspace: id, expecting: 5, what: "fitScreen New Column")
            try await Self.create(.action("newColumnLeft"), at: a, controller, workspace: id, expecting: 6, what: "fitScreen New Column Left")
            // Beside a zoomed pane, under fixed: the zoom ends; the daemon's widths stay.
            content.layoutModel.newColumnWidthModeOverride = .fixed
            #expect(services.registry.perform("toggleSplitZoom", invocation: Self.at(a)))
            try await PinnedPageTests.until({ services.daemon.store.screen(containing: a.pane.handle)?.zoomedPane == a.pane.handle },
                                            report: { Self.describe(controller) })
            try await Self.create(.action("newColumn"), at: a, controller, workspace: id, expecting: 7, what: "a column beside a zoomed pane",
                                  pointsToo: false)
        }
    }

    /// Starts a create (a key goes to the focused pane, an action to `pane`), waits for the daemon's
    /// new pane (`expecting` panes in all) and for whatever width a create sends after it, then
    /// checks each column's width in the daemon and, unless the create ends a zoom (the zoomed pane
    /// shows full width until then), in points. `splitsColumn`: the create splits the focused pane
    /// inside its column, so that column's panes change and only the other columns are checked.
    private static func create(_ start: Start, at pane: PaneController?, _ controller: WindowController, workspace: String,
                               expecting count: Int, what: String, pointsToo: Bool = true, splitsColumn: Bool = false) async throws {
        let content = try #require(controller.workspaceContent)
        let window = try #require(controller.window)
        let split = splitsColumn ? controller.focus.state.pane.flatMap { key in content.panes.values.first { $0.paneKey == key } } : nil
        let skipped = split.map { columnPanes(controller, of: $0) } ?? []
        let points = pointWidths(content).filter { !skipped.contains($0.key) }
        let stored = storedWidths(controller, workspace: workspace).filter { !skipped.contains($0.key) }
        switch start {
        case let .key(character, modifiers, keyCode):
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                      context: nil, characters: character, charactersIgnoringModifiers: character,
                                                      isARepeat: false, keyCode: keyCode))
            #expect(controller.services.keyRouter.interceptKeyDown(event, in: window), "\(what): the key router did not take the key")
        case let .action(action):
            let target = try #require(pane)
            #expect(controller.services.registry.perform(action, invocation: at(target)), "\(what): \(action) was refused")
        }
        try await PinnedPageTests.until({ daemonPanes(controller, workspace: workspace).count == count }, within: .seconds(30),
                                        report: { "\(what)\n" + describe(controller) })
        try await Task.sleep(for: .seconds(3))
        content.contentView.layoutSubtreeIfNeeded()
        let storedAfter = storedWidths(controller, workspace: workspace)
        for (handle, width) in stored {
            #expect(storedAfter[handle] == width,
                    "\(what): pane \(handle)'s column was \(width) of the viewport, now \(String(describing: storedAfter[handle]))\n\(describe(controller))")
        }
        guard pointsToo else { return }
        let after = pointWidths(content)
        for (handle, width) in points {
            let now = after[handle]
            #expect(now.map { abs($0 - width) < 0.5 } == true,
                    "\(what): pane \(handle) was \(width) pt wide, now \(String(describing: now)) pt\n\(describe(controller))")
        }
    }

    /// Each daemon pane's width in points in the window's layout (its target frame, not a frame in motion).
    private static func pointWidths(_ content: WorkspaceContentController) -> [UInt64: CGFloat] {
        content.contentView.layoutSubtreeIfNeeded()
        guard let active = content.layoutModel.activeScreenID, let view = content.layoutView.screenViews[active] else { return [:] }
        var widths: [UInt64: CGFloat] = [:]
        for pane in content.panes.values where isDaemonPane(pane) {
            if let frame = view.geometry.panes[pane.layoutPaneID] { widths[pane.pane.handle.rawValue] = frame.width }
        }
        return widths
    }

    /// The daemon handles of the panes in `pane`'s column (all of a split-tree screen's panes).
    private static func columnPanes(_ controller: WindowController, of pane: PaneController) -> Set<UInt64> {
        guard let screen = controller.services.daemon.store.screen(containing: pane.pane.handle) else { return [] }
        let column = screen.columns.first { $0.layout.paneIDs.contains(pane.pane.handle) }
        return Set((column?.layout.paneIDs ?? screen.layout.paneIDs).map(\.rawValue))
    }

    /// The daemon's stored width of each daemon pane's column; a screen without columns is one
    /// full-width column. By pane, since a split tree's column gets an id when it becomes one.
    private static func storedWidths(_ controller: WindowController, workspace: String) -> [UInt64: Double] {
        var widths: [UInt64: Double] = [:]
        for pane in daemonPanes(controller, workspace: workspace) {
            guard let screen = controller.services.daemon.store.screen(containing: pane.pane.handle) else { continue }
            let column = screen.columns.first { $0.layout.paneIDs.contains(pane.pane.handle) }
            widths[pane.pane.handle.rawValue] = screen.columns.isEmpty ? 1 : column?.width
        }
        return widths
    }

    private static func daemonPanes(_ controller: WindowController, workspace: String) -> [PaneController] {
        shown(controller, workspace: workspace).filter(isDaemonPane)
    }

    /// `pane` is the daemon's, not a create's provisional one (``ProvisionalPane``: its handle and its
    /// tab's surface live at 1 << 62 and above until the daemon's pane takes its place).
    private static func isDaemonPane(_ pane: PaneController) -> Bool {
        pane.pane.handle.rawValue < 1 << 62 && !pane.pane.tabs.contains { ProvisionalTab.isProvisional(surface: $0.surface) }
    }

    private static func at(_ pane: PaneController) -> ActionInvocation {
        ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.pane.id), origin: .cli)
    }

    /// The panes of `workspace`, shown in the window. A fresh session's Home can take the window
    /// back while the test waits, so each poll shows the workspace again.
    private static func shown(_ controller: WindowController, workspace: String) -> [PaneController] {
        if controller.workspaceContent?.workspace.id != workspace {
            controller.services.windows.show(workspaceID: workspace, in: controller.state)
        }
        guard let content = controller.workspaceContent, content.workspace.id == workspace else { return [] }
        return Array(content.panes.values)
    }

    private static func describe(_ controller: WindowController) -> String {
        let panes = controller.workspaceContent.map { Array($0.panes.values) } ?? []
        let screen = panes.first.flatMap { controller.services.daemon.store.screen(containing: $0.pane.handle) }
        return "workspace=\(controller.workspaceContent?.workspace.id ?? "-") panes=\(panes.map { $0.pane.handle.rawValue }.sorted())"
            + " columns=\(screen?.columns.map { "\($0.id.rawValue)@\($0.width):\($0.layout.paneIDs.map(\.rawValue))" } ?? [])"
            + " zoomed=\(String(describing: screen?.zoomedPane)) focused=\(controller.focus.state.pane ?? "-")"
    }
}
