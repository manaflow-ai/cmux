import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// GPU audit 2026-10-21, offender #1: the sidebar's show/hide slide moved the main pane's edge on
/// every frame, and the card resized its content with it, so every pane, terminal and Chromium page
/// laid out at a new width per frame (6.7 to 7.4 ms of main thread a frame, 81 to 89% of a 120 Hz
/// frame). The content now keeps one width for the whole slide, the widest the card reaches, rides
/// the moving edge, and lays out once: at the start of a hide, at the landing of a show.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarSlideHoldsContentTests {
    /// What a workspace does (`WorkspaceContentView`): its layout child has no autoresizing mask
    /// and is sized in `layout()`, so a frame change reaches it only on the next layout pass.
    private final class DeferredLayoutContent: NSView {
        let child = SettleProbe()
        override init(frame: NSRect) {
            super.init(frame: frame)
            child.autoresizingMask = []
            addSubview(child)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            child.frame = bounds
        }
    }

    /// A terminal stand-in: the width it has when it hears the motion settled.
    private final class SettleProbe: NSView, PaneMotionSettling {
        var settledWidths: [CGFloat] = []
        func paneMotionDidSettle() { settledWidths.append(bounds.width) }
    }

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

    private func withHold<T>(_ on: Bool?, _ body: () throws -> T) rethrows -> T {
        let store = TunableStore.shared
        store.activate(file: nil)
        store.register(SidebarTunables.all)
        let key = SidebarTunables.slideHoldsContent.key
        let previous = store.override(key)
        defer { store.set(key, previous) }
        store.set(key, on.map(TunableValue.bool))
        return try body()
    }

    /// Steps the sidebar's width the way its animator does, one window layout per frame.
    private func frame(_ root: WindowRootView, width: CGFloat) {
        root.sidebar.widthConstraint.constant = width
        root.layoutSubtreeIfNeeded()
    }

    @Test func holdingIsTheDefault() {
        withHold(nil) { #expect(SidebarTunables.slideHoldsContent.value) }
    }

    @Test func aHideSizesTheContentOnceAndItRidesTheEdge() throws {
        try withHold(nil) {
            let (window, root, content) = openRoot()
            defer { window.close() }
            let sidebar = root.sidebar.frame.width, card = root.contentHost.frame
            try #require(sidebar > 0 && content.frame == root.contentHost.bounds)
            root.sidebar.isWidthAnimating = true
            root.sidebar.onWidthMotionStart?(sidebar, 0)
            let held = card.width + sidebar
            #expect(content.frame == CGRect(x: 0, y: 0, width: held, height: card.height), "a hide lays the content out at its landing width first")
            var edge = root.contentHost.frame.minX
            for step in [0.75, 0.5, 0.25, 0] as [CGFloat] {
                frame(root, width: sidebar * step)
                #expect(root.contentHost.frame.minX < edge, "the card's edge follows the sidebar")
                edge = root.contentHost.frame.minX
                // The width is what the hold pins; the height follows the card (the window's
                // first layout passes can still move the card's top inset by a few points).
                #expect(content.frame == CGRect(x: 0, y: 0, width: held, height: root.contentHost.bounds.height),
                        "frame at \(step): the content resized to \(content.frame.width) mid-slide")
            }
            root.sidebar.isWidthAnimating = false
            #expect(root.contentHost.contentHold == nil)
            #expect(content.frame == root.contentHost.bounds)
            #expect(abs(content.frame.width - held) < 0.5)
        }
    }

    @Test func aShowKeepsTheWideContentUntilTheLanding() throws {
        try withHold(nil) {
            let (window, root, content) = openRoot()
            defer { window.close() }
            let sidebar = root.sidebar.frame.width
            frame(root, width: 0)
            let wide = root.contentHost.frame.width
            try #require(sidebar > 0 && abs(content.frame.width - wide) < 0.5)
            root.sidebar.isWidthAnimating = true
            root.sidebar.onWidthMotionStart?(0, sidebar)
            for step in [0.25, 0.5, 0.75, 1] as [CGFloat] {
                frame(root, width: sidebar * step)
                #expect(content.frame.minX == 0 && content.frame.width == wide,
                        "frame at \(step): the content resized to \(content.frame.width) mid-slide")
            }
            root.sidebar.isWidthAnimating = false
            #expect(content.frame == root.contentHost.bounds, "the landing fits the content to the card once")
            #expect(abs(content.frame.width - (wide - sidebar)) < 0.5)
        }
    }

    /// A toggle mid-slide turns the animation around from where it is: the content keeps the
    /// widest width either leg needs instead of resizing for the second one.
    @Test func aSlideThatTurnsAroundKeepsOneWidth() throws {
        try withHold(nil) {
            let (window, root, content) = openRoot()
            defer { window.close() }
            let sidebar = root.sidebar.frame.width, held = root.contentHost.frame.width + sidebar
            root.sidebar.isWidthAnimating = true
            root.sidebar.onWidthMotionStart?(sidebar, 0)
            frame(root, width: sidebar / 2)
            root.sidebar.onWidthMotionStart?(sidebar / 2, sidebar)
            frame(root, width: sidebar)
            #expect(content.frame.width == held)
            root.sidebar.isWidthAnimating = false
            #expect(content.frame == root.contentHost.bounds)
        }
    }

    /// Review (codex-xhigh) at 1f42c17: settlement used to reach a terminal before the workspace
    /// laid it out at the landed width, so it flushed the held (wide) grid first. A hide reversed
    /// into a show must settle the terminal once, at the final width.
    @Test func aReversedSlideSettlesTheTerminalAtTheLandedWidth() throws {
        try withHold(nil) {
            let (window, root, _) = openRoot()
            defer { window.close() }
            let content = DeferredLayoutContent()
            root.show(content)
            root.layoutSubtreeIfNeeded()
            content.frame = root.contentHost.bounds
            let sidebar = root.sidebar.frame.width
            root.sidebar.isWidthAnimating = true
            root.sidebar.onWidthMotionStart?(sidebar, 0)
            frame(root, width: sidebar / 2)
            let wide = content.child.bounds.width
            try #require(wide > root.contentHost.bounds.width, "the hide laid the content out wide")
            root.sidebar.onWidthMotionStart?(sidebar / 2, sidebar)
            root.sidebar.widthConstraint.constant = sidebar
            root.sidebar.isWidthAnimating = false
            let landed = root.contentHost.bounds.width
            #expect(content.child.settledWidths == [landed], "settled at \(content.child.settledWidths), landed at \(landed)")
        }
    }

    /// Debug Settings can turn the hold off: the content then follows the card on every frame.
    @Test func withTheHoldOffTheContentResizesEveryFrame() throws {
        try withHold(false) {
            let (window, root, content) = openRoot()
            defer { window.close() }
            let sidebar = root.sidebar.frame.width
            root.sidebar.isWidthAnimating = true
            root.sidebar.onWidthMotionStart?(sidebar, 0)
            #expect(root.contentHost.contentHold == nil)
            frame(root, width: sidebar / 2)
            #expect(content.frame == root.contentHost.bounds)
            root.sidebar.isWidthAnimating = false
        }
    }

    /// A square main pane (radius 0, the flat chrome styles) clips nothing at rest. While it holds
    /// content wider than itself it clips, so nothing shows past its edge, and Chromium pages and
    /// the overlay's rings see that edge (`CEFClipShape.clips(around:)`, `OverlayPlane.roundedClip`).
    @Test func aSquareMainPaneClipsOnlyWhileItHolds() throws {
        try withHold(nil) {
            let (window, root, content) = openRoot()
            defer { window.close() }
            root.contentHost.setCornerRadius(0)
            #expect(root.contentHost.layer?.masksToBounds == false, "a square card at rest clips nothing")
            let sidebar = root.sidebar.frame.width
            root.sidebar.isWidthAnimating = true
            root.sidebar.onWidthMotionStart?(sidebar, 0)
            try #require(root.contentHost.contentHold != nil)
            #expect(root.contentHost.layer?.masksToBounds == true, "the card clips what it holds")
            #expect(content.frame.width > root.contentHost.bounds.width)
            let probe = NSView(frame: CGRect(x: 0, y: 0, width: content.frame.width, height: 100))
            content.addSubview(probe)
            let clips = CEFClipShape.clips(around: probe)
            let card = probe.convert(root.contentHost.bounds, from: root.contentHost)
            #expect(clips.contains { abs($0.rect.maxX - card.maxX) < 0.5 }, "a page sees the card's edge: \(clips)")
            #expect(root.contentHost.setCornerRadius(0) == false, "a repeat with the hold on changes nothing")
            root.sidebar.isWidthAnimating = false
            #expect(root.contentHost.layer?.masksToBounds == false, "the landing takes the clip off again")
            #expect(content.frame == root.contentHost.bounds)
        }
    }

    /// A page held wider than the rounded card crosses its straight edge between the corners: the
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

    /// A sidebar on the right moves the card's trailing edge: the content rides that one. A
    /// workspace withdrawn hidden (no autoresizing mask) is left where it is.
    @Test func aRightSidebarSlideRidesTheTrailingEdge() {
        let card = MainPaneCardView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        card.setCornerRadius(10)
        let content = NSView(frame: card.bounds)
        content.autoresizingMask = [.width, .height]
        let withdrawn = NSView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        withdrawn.autoresizingMask = []
        card.addSubview(withdrawn)
        card.addSubview(content)
        card.contentHold = MainPaneCardView.ContentHold(width: 500, ridesTrailingEdge: true)
        #expect(content.frame == CGRect(x: -100, y: 0, width: 500, height: 300))
        card.setFrameSize(CGSize(width: 450, height: 300))
        #expect(content.frame == CGRect(x: -50, y: 0, width: 500, height: 300))
        card.contentHold = nil
        #expect(content.frame == card.bounds)
        #expect(withdrawn.frame == CGRect(x: 0, y: 0, width: 10, height: 10))
    }
}
