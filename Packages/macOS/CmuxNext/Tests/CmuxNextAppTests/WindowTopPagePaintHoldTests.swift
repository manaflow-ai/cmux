import AppKit
@testable import CmuxNextApp
@testable import CmuxNextPages
import CmuxNextSidebar
import Testing

/// No-flicker audit: a top page (App Store, History, Cloud) replaces the
/// window's workspace, and its web view is transparent until its document
/// paints. The window keeps the workspace on screen until then, as a pane
/// does for a page tab (`PanePaintHoldTests`).
@MainActor
@Suite(.serialized)
struct WindowTopPagePaintHoldTests {
    /// Counts how often it left its superview: a workspace that leaves
    /// detaches its panes.
    final class Workspace: NSView {
        var removals = 0
        override func viewWillMove(toSuperview newSuperview: NSView?) {
            if newSuperview == nil, superview != nil { removals += 1 }
            super.viewWillMove(toSuperview: newSuperview)
        }
    }

    private func root() -> WindowRootView {
        let model = SidebarModel()
        model.width = 240
        return WindowRootView(sidebar: SidebarContainerView(model: model), reduceTransparency: { false }, applyWindowBlur: { _, _ in })
    }

    @Test func anUnpaintedTopPageKeepsTheWorkspace() {
        let root = root()
        let workspace = NSView()
        root.show(workspace)
        let page = PanePaintHoldTests.Unpainted()
        root.show(page)
        #expect(root.content === page)
        #expect(workspace.superview === root.contentHost, "the window went empty before the page painted")
        #expect(page.alphaValue == 0)
        #expect(root.contentHost.subviews.last === page)

        page.paint()
        #expect(workspace.superview == nil)
        #expect(page.alphaValue == 1)
    }

    @Test func aPaintedTopPageReplacesTheWorkspaceAtOnce() {
        let root = root()
        let workspace = NSView()
        root.show(workspace)
        let page = PanePaintHoldTests.Unpainted()
        page.painted = true
        root.show(page)
        #expect(workspace.superview == nil)
        #expect(page.alphaValue == 1)
    }

    /// Selecting the workspace again before the page paints shows it at once
    /// and takes the page away; the workspace never left the window.
    @Test func goingBackBeforeThePagePaintsShowsTheWorkspace() {
        let root = root()
        let workspace = Workspace()
        root.show(workspace)
        let page = PanePaintHoldTests.Unpainted()
        root.show(page)
        root.show(workspace)
        #expect(root.content === workspace)
        #expect(workspace.superview === root.contentHost)
        #expect(page.superview == nil)
        #expect(page.alphaValue == 1)
        #expect(workspace.removals == 0, "the workspace left the window and detached its panes")
    }

    @Test func anUnpaintedPageWebViewKeepsTheWorkspace() throws {
        let root = root()
        let workspace = NSView()
        root.show(workspace)
        let web = try #require(PageWebView(pooledHost: .settings))
        let page = InternalPageView(key: "top-page", page: .settings, content: web)
        root.show(page)
        #expect(workspace.superview === root.contentHost, "the window went empty before the page painted")
        #expect(page.alphaValue == 0)
    }

    /// Cursor review (#18612): a second top page that has not painted either
    /// keeps the workspace, not the first page, which never showed.
    @Test func aSecondUnpaintedPageKeepsTheWorkspace() {
        let root = root()
        let workspace = NSView()
        root.show(workspace)
        let first = PanePaintHoldTests.Unpainted()
        root.show(first)
        let second = PanePaintHoldTests.Unpainted()
        root.show(second)
        #expect(root.content === second)
        #expect(workspace.superview === root.contentHost, "the window went empty before the second page painted")
        #expect(first.superview == nil)
        #expect(first.alphaValue == 1, "a page view is reused; it must not stay invisible")
        #expect(second.alphaValue == 0)

        second.paint()
        #expect(workspace.superview == nil)
        #expect(second.alphaValue == 1)
    }
}
