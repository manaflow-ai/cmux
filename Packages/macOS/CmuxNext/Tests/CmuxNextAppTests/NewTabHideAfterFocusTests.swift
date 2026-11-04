import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextDaemon
import CmuxNextHistory
import CmuxNextTestSupport
import Foundation
import Testing

/// TERMINAL CREATE COST (STATUS 11399, 11648, 11732): New Terminal Tab over a History tab spent 8-9 ms of its key
/// turn hiding the History page. The pane hid the old tab (`TabContentCache.withdraw` -> conceal ->
/// `setContentVisible(false)`) while the page still had the keyboard, so AppKit searched the window's whole key view
/// loop for a replacement first responder (`-[NSView nextValidKeyView]`, `_NSComputeFirstKeyViewVisuallyInDirection`,
/// 5-5.5 ms on cmux21). As Chrome does when it activates a tab (focus moves first, then the old WebContents hides),
/// the keyboard now leaves the old tab before it hides.
@Suite(.serialized, .closesItsWindows)
@MainActor struct NewTabHideAfterFocusTests {
    private static func tree() -> DaemonTree {
        let tabs = [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~"),
                    TabSnapshot(surface: SurfaceID(rawValue: 2), kind: .browser, url: HistoryPageAddress.string,
                                browserRenderer: "frontend", browserEngine: "webkit")]
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: tabs)
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"new-tab-hide-after-focus-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// Waits until the main run loop's pass has committed (a one-shot before-waiting observer after every other one).
    private static func nextCommittedPass() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue,
                                                              false, CFIndex.max) { _, _ in
                done.resume()
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
        }
    }

    @Test func theKeyboardLeavesTheOldTabBeforeItHides() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree())
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let historyTab = try #require(store.tab(surface: SurfaceID(rawValue: 2)))
        // The History page the person looks at (the real page tab: its conceal hides its view).
        let page = HistoryPageTab(id: BrowserTabID(rawValue: historyTab.id), engine: .webkit, profile: .default, source: services.historyPage)
        _ = services.cache.install(page, for: historyTab.id)
        defer { services.cache.browsers[historyTab.id] = nil }

        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services, state: state)
        defer { pane.teardown() }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        pane.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        window.contentView = pane.view
        window.orderFrontRegardless()
        pane.setPresence(.visible) // the layout reports the pane on screen: its tab renders, and the cache conceals it when it leaves
        state.selection.select(historyTab.id, in: pane.paneKey)
        pane.syncStripFromStore()
        pane.view.layoutSubtreeIfNeeded()
        for _ in 0..<12 where pane.currentTabKey != historyTab.id || page.contentView.window == nil { await Self.nextCommittedPass() }
        try #require(pane.currentTabKey == historyTab.id && page.contentView.window === window, "the History page never showed")
        try #require(services.cache.phase(of: historyTab.id) == .mountedVisible && !page.contentView.isHidden,
                     "the History page does not show in the cache (phase \(services.cache.phase(of: historyTab.id)))")

        // The page has the keyboard (a key view inside it is the first responder).
        let field = KeyLoopCountingView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        page.contentView.addSubview(field)
        try #require(window.makeFirstResponder(field), "the page's key view did not take the keyboard")
        field.keyLoopAsks = 0

        // The key's turn of New Terminal Tab (`PaneController.newTerminalTabNow`): the stand-in in the store, selected.
        let standIn = ProvisionalTab()
        defer { services.cache.release(standIn.id) }
        store.intend(.createTab(pane: model.handle, provisional: standIn.terminal(TerminalID.generate(), cwd: nil)),
                     transaction: ClientTransactionID.generate())
        pane.selectWhenReported(surface: standIn.surface)

        try #require(pane.currentTabKey == standIn.id, "the key's turn did not switch to the stand-in")
        // The key's turn hid the History page through the cache (conceal -> setContentVisible(false)), not only its pane view.
        try #require(page.contentView.isHidden, "the History page did not hide in the key's turn: the test no longer reaches the case")
        let resigned = try #require(field.resignedWhilePageShowed.first,
                                    "the page's key view never gave up the keyboard (first responder now: \(String(describing: window.firstResponder)))")
        #expect(resigned, "the page's key view gave up the keyboard only after its page hid: AppKit walked the key view loop \(field.keyLoopAsks) asks")
        #expect(field.keyLoopAsks == 0, "AppKit asked the page's key view for the key view loop \(field.keyLoopAsks) times")
    }
}

/// A key view that records, each time it gives up the keyboard, whether its page still showed (no hidden ancestor), and
/// counts AppKit's key view loop asks (`nextValidKeyView`, `previousValidKeyView`). AppKit replaces a hidden first
/// responder only after the hide set its flag, so a key view that gives up the keyboard behind a hidden ancestor was walked.
private final class KeyLoopCountingView: NSView {
    var keyLoopAsks = 0
    var resignedWhilePageShowed: [Bool] = []
    override var acceptsFirstResponder: Bool { true }
    override func resignFirstResponder() -> Bool {
        resignedWhilePageShowed.append(!isHiddenOrHasHiddenAncestor)
        return super.resignFirstResponder()
    }
    override var nextValidKeyView: NSView? {
        keyLoopAsks += 1
        return super.nextValidKeyView
    }
    override var previousValidKeyView: NSView? {
        keyLoopAsks += 1
        return super.previousValidKeyView
    }
}
