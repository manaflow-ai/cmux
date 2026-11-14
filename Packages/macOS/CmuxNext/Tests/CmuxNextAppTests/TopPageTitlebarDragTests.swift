import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextTestSupport
import Foundation
import Testing

/// A web top page (Import history's "Bring your history", Stats) fills the main pane with no tab
/// strip above it, so its top row is the window's title bar, like the sidebar header beside it.
/// The window moved only from the sidebar's top strip (https://github.com/manaflow-ai/cmux/issues/36897).
/// The page's controls there must keep their clicks, and AppKit cannot see them, so the page
/// reports a drag or double-click on its row's background and the window takes it in the top row
/// of a top page only (``PageTitleRowPress``).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
        .closesItsWindows)
struct TopPageTitlebarDragTests {
    @Test(arguments: [InternalPageID.importHistory, .stats])
    func aTopPagesTitleRowMovesTheWindowAndItsControlsKeepTheirPress(_ id: InternalPageID) async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            try #require(TopPages.show(.page(id), services: services) != nil, "\(id.rawValue) did not show as a top page")
            try #require(controller.shownTopPage == .page(id))
            let page = try #require(controller.topPages.views[.page(id)] as? InternalPageView)
            let web = try #require(PageWebView.shown(in: page.content), "\(id.rawValue) is a web page")
            window.contentView?.layoutSubtreeIfNeeded()
            let shown = page.convert(page.bounds, to: nil)
            try #require(TitlebarDragPolicy.topRowContains(CGPoint(x: shown.midX, y: shown.maxY - 2), in: window),
                         "the page reaches the window's top row (page \(shown))")

            // The page's own row background: a drag or a double-click there moves the window.
            let zoom = max(web.pageZoom, 0.01)
            let row = PageTitleRowPress.Report(kind: .drag, point: CGPoint(x: web.bounds.midX / zoom, y: 4))
            #expect(web.takesTitleRowPress(row), "a drag on \(id.rawValue)'s title row stays put")
            #expect(web.takesTitleRowPress(.init(kind: .double, point: row.point)))
            // Below the row the page keeps its presses.
            #expect(!web.takesTitleRowPress(.init(kind: .drag, point: CGPoint(x: row.point.x, y: web.bounds.height / zoom / 2))))
            // AppKit hands a press over the page to the page (its controls take it, or it reports the drag).
            let top = CGPoint(x: shown.midX, y: shown.maxY - 2)
            let frameView = try #require(window.contentView?.superview)
            #expect(frameView.hitTest(frameView.convert(top, from: nil))?.isDescendant(of: web) == true, "the press lands on the page")
            #expect(TitlebarDragPolicy.decide(at: top, in: window) == .staysPut)
        }
    }
}

/// The title row rule without an app: a pane above a page answers for its own top row.
@MainActor @Suite(.closesItsWindows) struct TitleRowHostPaneTests {
    /// A page in a pane tab sits under the pane's tab strip: its top is no title row.
    @Test func aPageInAPaneDoesNotMoveTheWindow() throws {
        do {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
                                  styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let pane = DecidingContainer(frame: window.contentView!.bounds)
            window.contentView!.addSubview(pane)
            let host = TitleRowHostView(frame: pane.bounds)
            pane.addSubview(host)
            let content = NSView(frame: host.bounds)
            host.addSubview(content)
            let top = CGPoint(x: 300, y: 398)
            #expect(TitlebarDragPolicy.topRowContains(top, in: window))
            #expect(!TitleRowHostView.takesTitleRowPress(from: content, atWindowPoint: top))
            pane.removeFromSuperview()
            window.contentView!.addSubview(host)
            #expect(TitleRowHostView.takesTitleRowPress(from: content, atWindowPoint: top))
            // Native content answers as with no host: background moves the window, a control keeps its press.
            #expect(host.titlebarPress(atWindowPoint: top) == .movesWindow)
            let button = NSButton(frame: content.bounds)
            content.addSubview(button)
            #expect(host.titlebarPress(atWindowPoint: top) == .staysPut)
            window.close()
        }
    }
}

private final class DecidingContainer: NSView, TitlebarPressDeciding {
    func titlebarPress(atWindowPoint windowPoint: CGPoint) -> TitlebarPress { .staysPut }
}
