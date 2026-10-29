import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// A page tab that shows a ``PageWebView``, made in a test root.
@MainActor
private final class PanePlacedPage: InternalPageProvider {
    let page = InternalPageID(rawValue: "test.pane-placed")
    let title = "Pane placed"
    let symbol = "doc"
    let root: URL
    private(set) var made: [PageWebView] = []

    init(root: URL) { self.root = root }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let descriptor = PageDescriptor(id: "test.pane-placed", resource: "pane-placed", processGroup: .solo, namespaces: [])
        guard let view = PageWebView(descriptor: descriptor, root: root, routes: [], deadlines: .testing()) else { return NSView() }
        made.append(view)
        return view
    }
}

/// The app side: the pane that shows a page tab names its Chromium window on the tab's page
/// (``PageWebView/chromiumWindow``), so the page tabs of one pane share one window and a tab shown in another pane
/// moves its page there. Behind `pageTabsShareChromiumWindow` (``InternalPageTabStore/sharesChromiumWindows``).
@MainActor @Suite(.serialized)
struct InternalPageChromiumWindowTests {
    private let paneA = PageChromiumWindow(window: "window-1", pane: "pane-a")
    private let paneB = PageChromiumWindow(window: "window-1", pane: "pane-b")

    private static func pageRoot() throws -> URL {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appending(path: "pane-placed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<html><body></body></html>".utf8).write(to: root.appending(path: "index.html"))
        return root
    }

    @Test func thePaneThatShowsAPageTabNamesItsWindowAndAMoveRenamesIt() throws {
        let root = try Self.pageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pages = InternalPageTabStore()
        pages.sharesChromiumWindows = true
        let provider = PanePlacedPage(root: root)
        pages.register(provider)
        let store = DaemonStore()
        let first = pages.open(provider.page, in: paneA.pane, of: store)
        let second = pages.open(provider.page, in: paneA.pane, of: store)

        _ = try #require(pages.view(for: first, in: paneA))
        _ = try #require(pages.view(for: second, in: paneA))
        try #require(provider.made.count == 2)
        #expect(provider.made.allSatisfy { $0.chromiumWindow == paneA }, "two tabs of one pane: one window")

        // The second tab shows in pane B: its page moves to B's window; the first stays.
        _ = try #require(pages.view(for: second, in: paneB))
        #expect(provider.made.count == 2, "a move makes no new page")
        #expect(provider.made[1].chromiumWindow == paneB)
        #expect(provider.made[0].chromiumWindow == paneA)

        // A caller that is not a pane leaves the page where it is.
        _ = pages.view(for: second)
        #expect(provider.made[1].chromiumWindow == paneB)
        pages.close(first)
        pages.close(second)
    }

    @Test func aStorePageTabJoinsItsPanesWindow() throws {
        let root = try Self.pageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pages = InternalPageTabStore()
        pages.sharesChromiumWindows = true
        let provider = PanePlacedPage(root: root)
        pages.register(provider)
        let store = DaemonStore()
        var tab = TabSnapshot(surface: SurfaceID(rawValue: 301), kind: .conversation, title: "about:blank")
        tab.conversation = ConversationTabRef(page: provider.page.rawValue, route: nil)
        let pane = PaneSnapshot(id: PaneID(rawValue: 201), tabs: [tab])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 101), layout: .leaf(pane.id), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w", screens: [screen])]))
        let model = try #require(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first)

        _ = try #require(pages.view(forStoreTab: model, in: store, local: true, window: nil, pane: paneA))
        #expect(provider.made.first?.chromiumWindow == paneA)
        _ = try #require(pages.view(forStoreTab: model, in: store, local: true, window: nil, pane: paneB))
        #expect(provider.made.count == 1)
        #expect(provider.made.first?.chromiumWindow == paneB)
    }

    /// With the feature off, every page keeps a window of its own.
    @Test func withTheFeatureOffNoPageNamesAPaneWindow() throws {
        let root = try Self.pageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pages = InternalPageTabStore()
        let provider = PanePlacedPage(root: root)
        pages.register(provider)
        let key = pages.open(provider.page, in: paneA.pane, of: DaemonStore())
        _ = try #require(pages.view(for: key, in: paneA))
        #expect(try #require(provider.made.first).chromiumWindow == nil)
        pages.close(key)
    }
}
