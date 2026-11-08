import AppKit
@testable import CmuxNextPages
import Foundation
import Testing

/// The docked Home's Channels view is a page inside the dock's view, not the tab's content itself. The
/// focus model finds the Chromium page a tab shows by ``PageWebView/shown(in:)``; when that saw only a
/// content that IS a page, Channels in Chromium never got the keyboard at its first open: the hidden
/// WebKit stand-in stayed first responder and the cmux window took the keys back from the page
/// window (journey found-desync-channels-type, red on feat f2f3083b, 2026-10-31; STATUS 1582).
@MainActor
struct PageWebViewShownInContainerTests {
    /// A container like the docked Home: it shows a page or another view.
    final class Dock: NSView, PageWebViewContainer {
        var page: PageWebView?
        var showsPage = true
        var shownPageView: PageWebView? { showsPage ? page : nil }
    }

    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-shown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func page() throws -> PageWebView {
        try #require(PageWebView(descriptor: PageDescriptor(id: "test.shown-in", resource: "shown-in", namespaces: []), root: root, routes: []))
    }

    @Test func aContainerNamesThePageItShows() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let dock = Dock(frame: .zero)
        dock.page = try page()
        dock.addSubview(try #require(dock.page))
        #expect(PageWebView.shown(in: dock) === dock.page, "the page inside the dock was not found: Channels never gets the keyboard")
    }

    @Test func aContainerShowingAnotherViewShowsNoPage() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let dock = Dock(frame: .zero)
        dock.page = try page()
        dock.showsPage = false
        #expect(PageWebView.shown(in: dock) == nil)
    }

    @Test func aPageIsItsOwnShownPage() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try page()
        #expect(PageWebView.shown(in: page) === page)
        #expect(PageWebView.shown(in: NSView()) == nil)
    }
}
