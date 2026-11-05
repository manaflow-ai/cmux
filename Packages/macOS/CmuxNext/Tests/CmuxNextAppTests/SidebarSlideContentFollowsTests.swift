import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// The sidebar's show/hide slide moves the main pane's edge on every frame, and the content
/// follows the card on every frame (#29894; Leo 2026-11-01: content that kept one width through
/// the slide shifted and snapped back). The hold that sized it once (`sidebar.slideHoldsContent`,
/// opt-in) was deleted on 2026-11-05 with the other perf switches; this is the only path.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarSlideContentFollowsTests {
    private func openRoot() -> (NSWindow, WindowRootView, NSView) {
        _ = NSApplication.shared
        let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        let content = NSView()
        root.show(content)
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        // At rest the content fills the card; autoresizing from the card's first (zero) size can
        // leave it a fraction off, which is not what these tests measure.
        content.frame = root.contentHost.bounds
        return (window, root, content)
    }

    /// Steps the sidebar's width the way its animator does, one window layout per frame.
    private func frame(_ root: WindowRootView, width: CGFloat) {
        root.sidebar.widthConstraint.constant = width
        root.layoutSubtreeIfNeeded()
    }

    /// Mid-slide the content fills the card at the card's width of that frame, and a square card
    /// clips nothing.
    @Test func theContentResizesEveryFrame() throws {
        let (window, root, content) = openRoot()
        defer { window.close() }
        root.contentHost.setCornerRadius(0)
        let sidebar = root.sidebar.frame.width
        root.sidebar.isWidthAnimating = true
        frame(root, width: sidebar / 2)
        #expect(content.frame == root.contentHost.bounds)
        #expect(root.contentHost.layer?.masksToBounds == false, "a square card clips nothing")
        frame(root, width: sidebar / 4)
        #expect(content.frame == root.contentHost.bounds)
        root.sidebar.isWidthAnimating = false
    }

    /// A page wider than the rounded card crosses its straight edge between the corners: the
    /// page's clip shape (a child window, which no layer mask reaches) still cuts it there.
    @Test func aPageAcrossTheRoundedCardsStraightEdgeIsCut() throws {
        let card = CEFClipShape.RoundedRect(rect: CGRect(x: 100, y: 0, width: 400, height: 600), radius: 12)
        let page = CGRect(x: 0, y: 200, width: 300, height: 200)
        #expect(!CEFClipShape.cutsCorner(of: card, into: page), "the page sits between the card's corner bands")
        let shape = try #require(CEFClipShape.path(bounds: page, clips: [card]))
        #expect(abs(shape.boundingBoxOfPath.minX - 100) < 0.5, "the page shows only from the card's edge on")
        let inside = CGRect(x: 150, y: 200, width: 300, height: 200)
        #expect(CEFClipShape.path(bounds: inside, clips: [card]) == nil, "a page inside the card is a plain rectangle")
    }
}
