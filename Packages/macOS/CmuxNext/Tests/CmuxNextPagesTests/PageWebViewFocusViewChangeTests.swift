@testable import CmuxNextPages
import AppKit
import CmuxNextPagesTestSupport
import CmuxNextTestSupport
import Foundation
import Testing

/// A page shown before its Chromium page exists (a cold New Tab page at the first Cmd-N of a launch)
/// has its WebKit view as the keyboard target until Chromium arrives. When it arrives, the pane's
/// focus model must hand the keys on: the page tells its host (``PageChromiumHosting/focusViewChanged(_:)``)
/// instead of granting Chromium focus behind the model. The grant alone left the hidden WebKit view
/// first responder and the focus applier with no focused page, for good (action fuzz 2026-10-31:
/// W1 "appkit content (PageWebView) != model agentPage", W4 "chromium page nil != model tab").
/// A page with no focus model still grants it itself.
@MainActor
@Suite(.closesItsWindows)
struct PageWebViewFocusViewChangeTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.focus-view", resource: "focus-view", namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-focus-view-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    /// The view in a window, its WebKit view first responder: a pane that showed it and focused it.
    private func shownAndFocused(_ hosting: FakeChromiumHosting) throws -> (PageWebView, NSWindow) {
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: "#/start", chromium: hosting))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        try #require(window.contentView).addSubview(view)
        window.makeFirstResponder(view.webKitView)
        return (view, window)
    }

    @Test func aChromiumPageThatArrivesAfterThePageShowedTellsItsHost() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let (view, window) = try shownAndFocused(hosting)
        defer {
            window.closeAfterTest()
            view.close()
        }
        view.chromiumClock = PageTestClock.never
        let focusViews = FocusViewRecord()
        hosting.focusModel = { page in
            focusViews.views.append(page.focusView)
            return true
        }
        try #require(window.firstResponder === view.webKitView)

        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        #expect(focusViews.views.count == 1, "the host was not told that Chromium's page takes the keys now")
        #expect((focusViews.views.first ?? nil) === page.contentView)
        #expect(page.focusAsks.isEmpty, "the page granted Chromium focus behind the host's focus model: \(page.focusAsks)")
    }

    @Test func withNoHostThePageTakesTheKeysItselfWhenItsWebKitViewHadThem() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let (view, window) = try shownAndFocused(hosting)
        defer {
            window.closeAfterTest()
            view.close()
        }
        view.chromiumClock = PageTestClock.never

        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        #expect(page.focusAsks == [true])
    }
}

/// The focus view at each ``PageChromiumHosting/focusViewChanged(_:)`` call.
@MainActor
private final class FocusViewRecord {
    var views: [NSView?] = []
}
