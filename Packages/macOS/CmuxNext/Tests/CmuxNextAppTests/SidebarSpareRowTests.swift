import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import QuartzCore
import Testing

/// Cmd-N's turn makes no sidebar row view (SHORTCUT PERF 2). On the bench (light session, 120 Hz) the sidebar redraw in
/// Cmd-N's turn took 10.4 ms, 5.7 ms of it in `WorkspaceRowView.init` for the new workspace's row. Like Chrome's spare
/// renderer, the list keeps one workspace row view made after a frame committed, and the next new workspace row takes it:
/// the key's turn configures and places a row view, it never makes one.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarSpareRowTests {
    private static func sections(_ ids: [Int]) -> [CmuxNextSidebar.SidebarSection] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: ids.map {
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64($0)), key: nil,
                              resourceID: ResourceID(rawValue: "ws-\($0)"), name: "w\($0)")
        }))
        return SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
    }

    private static func key(_ id: Int) throws -> SidebarRowKey {
        .workspace(try #require(sections([id]).first?.workspaces.first?.id))
    }

    /// Workspaces `ids` in a sidebar in a window, the first selected. Returns the window to close.
    private static func sidebar(_ ids: [Int]) throws -> (SidebarModel, SidebarView, NSWindow) {
        let start = sections(ids)
        let model = SidebarModel(sections: start, activeWorkspaceID: try #require(start.first?.workspaces.first?.id))
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 480)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        return (model, sidebar, window)
    }

    /// Waits until two main run-loop passes have committed, so work after a frame's commit has run (the signal
    /// `AfterFrameCommit` uses: a one-shot before-waiting observer after every other observer of the pass).
    private static func nextTurns() async {
        for _ in 0..<2 {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue,
                                                                  false, CFIndex.max) { _, _ in
                    done.resume()
                    CFRunLoopWakeUp(CFRunLoopGetMain())
                }
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
            }
        }
    }

    /// Every workspace row view the list holds now, shown, parked or waiting.
    private static func rowViews(in list: SidebarListView) -> Set<ObjectIdentifier> {
        Set(list.subviews.compactMap { $0 as? WorkspaceRowView }.map(ObjectIdentifier.init))
    }

    /// Three Cmd-N, each in its own turn as a person presses them, with no parked row view to take (every row shows):
    /// each new workspace's row shows in a view the list held before the press, and shows its title.
    @Test func aNewWorkspaceRowTakesAViewMadeBeforeItsPress() async throws {
        var ids = Array(1...6)
        let (model, sidebar, window) = try Self.sidebar(ids)
        defer { window.close() }
        let list = sidebar.list
        for press in 0..<3 {
            await Self.nextTurns()
            let before = Self.rowViews(in: list)
            ids.insert(100 + press, at: 0)
            model.sections = Self.sections(ids)
            list.reload(animated: false, fromModel: true)
            let view = try #require(list.rowViews[try Self.key(100 + press)], "press \(press): the new row has no view")
            #expect(before.contains(ObjectIdentifier(view)),
                    "press \(press): Cmd-N's turn made the new row's view (WorkspaceRowView.init, 5.7 ms on the bench)")
            #expect((view as? WorkspaceRowView)?.title.stringValue == "w\(100 + press)", "press \(press): the new row shows no title")
            #expect(!view.isHidden && view.alphaValue == 1, "press \(press): the new row's view is not shown")
        }
    }

    /// The waiting view never shows a row: it is hidden, and no row of the list is drawn by it.
    @Test func theWaitingViewShowsNothing() async throws {
        let (_, sidebar, window) = try Self.sidebar(Array(1...4))
        defer { window.close() }
        let list = sidebar.list
        await Self.nextTurns()
        let shown = Set(list.rowViews.values.map(ObjectIdentifier.init))
        let waiting = list.subviews.compactMap { $0 as? WorkspaceRowView }.filter { !shown.contains(ObjectIdentifier($0)) }
        #expect(waiting.allSatisfy { $0.isHidden }, "a row view that is not a row of the list shows")
    }
}
