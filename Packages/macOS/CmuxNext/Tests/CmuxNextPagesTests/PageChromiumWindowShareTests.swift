import AppKit
import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing

/// A page tab's Chromium page joins its pane's Chromium window (``PageWebView/chromiumWindow``,
/// ``PageChromiumWindow``). The page is made in the window its view names when its document starts; a live page
/// moves when its tab shows in another pane; a page whose tab moved while it was being made moves once it attaches.
@MainActor @Suite(.serialized)
struct PageChromiumWindowShareTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.pane-window", resource: "pane-window", processGroup: .solo, namespaces: [])
    private let paneA = PageChromiumWindow(window: "window-1", pane: "pane-a")
    private let paneB = PageChromiumWindow(window: "window-1", pane: "pane-b")

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-pane-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func makeHost(_ hosting: FakeChromiumHosting, lazy: Bool) -> WebUIHost {
        WebUIHost(chromium: hosting, openPanel: nil, memory: QuietMemoryRegistry(), deadlines: LifecycleDeadlineRig.never,
                  startsPagesAtFirstShow: lazy)
    }

    @Test func aPageOpenedForAPaneIsMadeInItsWindow() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let host = makeHost(hosting, lazy: false)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [], chromiumWindow: paneA)))
        defer { host.close(view) }
        await view.chromiumStart?.value
        #expect(hosting.windows == [paneA])
        #expect(try #require(hosting.made.first).moves.isEmpty)
    }

    @Test func aPageWithNoPaneGetsAWindowOfItsOwn() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let host = makeHost(hosting, lazy: false)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        await view.chromiumStart?.value
        #expect(hosting.windows == [nil])
    }

    /// The pane sets the window as it shows the tab, before the page's first show starts its document.
    @Test func aPaneSetBeforeTheFirstShowIsTheWindowThePageIsMadeIn() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let host = makeHost(hosting, lazy: true)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        view.chromiumWindow = paneA
        let window = PagePreloadPageTests.shownWindow()
        defer { window.close() }
        // AppKit reports the off-screen test window covered: its node reads visible.
        let visibility = WindowVisibilitySource.of(window, read: { _ in .visible })
        window.contentView?.addSubview(view)
        await view.chromiumStart?.value
        withExtendedLifetime(visibility) {}
        #expect(hosting.windows == [paneA])
        #expect(try #require(hosting.made.first).moves.isEmpty)
    }

    @Test func aLivePageMovesWhenItsTabShowsInAnotherPane() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let host = makeHost(hosting, lazy: false)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [], chromiumWindow: paneA)))
        defer { host.close(view) }
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        view.chromiumWindow = paneB
        #expect(page.moves == [paneB])
        view.chromiumWindow = paneB
        #expect(page.moves == [paneB], "the same pane again moves nothing")
        view.chromiumWindow = paneA
        #expect(page.moves == [paneB, paneA], "moved back")
        view.chromiumWindow = nil
        #expect(page.moves == [paneB, paneA], "no pane leaves the page where it is")
        #expect(hosting.made.count == 1, "a move makes no new page")
    }

    /// The tab moved to pane B after the page was asked for in pane A, before it attached: it moves on attach.
    @Test func aTabMovedWhileItsPageIsMadeMovesThePageOnceItAttaches() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let host = makeHost(hosting, lazy: false)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [], chromiumWindow: paneA)))
        defer { host.close(view) }
        let paneB = paneB
        hosting.onMade = { [weak view] _ in view?.chromiumWindow = paneB }
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        #expect(hosting.windows == [paneA])
        #expect(page.moves == [paneB])
    }
}
