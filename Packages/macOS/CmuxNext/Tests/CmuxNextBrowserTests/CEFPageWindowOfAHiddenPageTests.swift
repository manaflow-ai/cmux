import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// 2 Chromium pages at one place of a window, each with its own pane host, as 2 pages of one pane have while the pane
/// goes from one to the other: the app shows the one and tells the other `not visible` (`CEFTab.setContentVisible`).
/// Chromium has one page window at that place then, the window of the page that shows.
///
/// A tab says which window is its page window by the window's frame (`CEFTab.isPageWindow`): a child of the tab's
/// window at the frame of the tab's host view. The 2 pages have the same frame, so the frame alone cannot say whose
/// window it is. Want: the page that the app told `not visible` does not say that the window at its place is its page
/// window, and the page that shows does. A page asks this to know if it has the keys (the key window is its page
/// window), so with 2 answers of `yes` 2 pages of one place have the keys at one time.
///
/// The model: no Chromium. Each tab has a pane host with a shim that does nothing, and the page window is a
/// borderless child window that the row puts at the frame of the first page's host view. The row does not make the
/// window key: it reads the tab's answer for the window, which is what the question for the key window reads. The
/// read is in the turn of the hide: the tab hides its host view at the end of that turn, and the row does not wait.
@MainActor @Suite(.serialized, .closesItsWindows) struct CEFPageWindowOfAHiddenPageTests {
    /// The runtimes of the rows: a shown tab keeps work for later that reads its runtime after the row's end.
    private static var runtimes: [CEFRuntime] = []

    private static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            name == "cmux_shim_create_window" ? unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self) : unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }

    /// A tab with a pane host of its own, with its content view over the whole of `parent`.
    private static func page(_ runtime: CEFRuntime, over parent: NSView) throws -> CEFTab {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        tab.contentView.frame = parent.bounds
        // The content view enters the window: the tab shows itself in its host.
        parent.addSubview(tab.contentView)
        parent.layoutSubtreeIfNeeded()
        try #require(host.visibleTab === tab && host.hostView.superview === tab.contentView,
                     "setup: the tab's host does not show the tab in the tab's content view")
        return tab
    }

    @Test func aPageThatTheAppHidDoesNotSayThatTheWindowAtItsPlaceIsItsPageWindow() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appending(path: "page-window-of-a-hidden-page-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = CEFRuntime(shim: try Self.library(), storage: CEFProfileStorage(root: root))
        Self.runtimes.append(runtime)
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 400, height: 300), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = content
        let shown = try Self.page(runtime, over: content), hidden = try Self.page(runtime, over: content)
        let host = shown.host.hostView
        let pageWindow = NSWindow(contentRect: window.convertToScreen(host.convert(host.bounds, to: nil)), styleMask: [.borderless],
                                  backing: .buffered, defer: true)
        pageWindow.isReleasedWhenClosed = false
        window.addChildWindow(pageWindow, ordered: .above)
        defer {
            window.removeChildWindow(pageWindow)
            pageWindow.close()
            window.close()
        }
        try #require(pageWindow.parent === window, "setup: the page window is not a child window of the window")
        try #require(shown.isPageWindow(pageWindow) && hidden.isPageWindow(pageWindow),
                     "setup: the 2 pages are not at one place: the window at the first page's frame is not the page window of each")

        hidden.setContentVisible(false)
        try #require(hidden.isContentHidden && !shown.isContentHidden, "setup: the tab did not record the app's hide of the second page, and only of it")
        let ofTheShown = shown.isPageWindow(pageWindow), ofTheHidden = hidden.isPageWindow(pageWindow)
        print("CEFPageWindowOfAHiddenPageTests: 2 pages at one place, the second told `not visible`: the window at the place is the "
            + "page window of the page that shows: \(ofTheShown), want true; of the page that the app hid: \(ofTheHidden), want false")
        #expect(ofTheShown, "the page that shows does not say that the window at its place is its page window")
        #expect(!ofTheHidden, "a page that the app told `not visible` says that the window at its place is its page window: 2 pages of one place have the keys at one time")
    }
}
