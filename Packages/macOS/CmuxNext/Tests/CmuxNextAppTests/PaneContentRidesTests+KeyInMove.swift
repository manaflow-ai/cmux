import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTabs
import CmuxNextTestSupport
import QuartzCore
import Testing

/// `PaneContentRidesTests`, a resize key in the hold of a move.
///
/// A split makes a pane smaller, and the pane's host holds the old picture at the pane's leading top corner until the
/// move's end. A resize key in that time starts the key's own hold on the same pane. The old picture then stays at
/// the corner where the move had it: in no frame does it go farther than an edge of its pane goes in that frame. The
/// frame that ends the move is the one that showed the fault: the key's hold took the content there and put it at the
/// pane's other edge, so a picture two times as wide as its pane went half its width in one frame.
///
/// Two kinds of content have a key hold of their own: content that the pane's host holds whole (a chat with its
/// tools in the tab row; here the layout's plain content), and the Home in a page, which its content area holds
/// (here the app's docked Home page in the app's pane content view).
extension PaneContentRidesTests {
    typealias AllKinds = PaneContentFollowsPaneAllKindsTests

    /// `nativeBesideAPane` with its right pane split to the right: that pane gets narrower and keeps its leading edge.
    static var rightPaneSplit: [LayoutScreen] {
        let halves = SplitNode.split(SplitID("new"), axis: .horizontal, ratio: 0.5, a: .leaf(Commit.right), b: .leaf(Commit.added))
        return columns([LayoutColumn(id: "c", width: 1, root: .split(SplitID("s"), axis: .horizontal, ratio: 0.5, a: .leaf(Commit.left), b: halves))])
    }

    /// What the frames after a resize key in a move's hold showed.
    struct KeyInMove {
        /// The frames in which the old picture's leading edge went farther than an edge of its pane did.
        var jumps: [String] = []
        /// The frame that ended the move, counted from the key; nil: the move did not end.
        var end: Int?
        /// The pane was still on the key's spring in the frame that ended the move.
        var springsAtEnd = false
        /// The frames stepped.
        var frames = 0
    }

    /// Steps the frames after a resize key until nothing moves, and reads where `picture` is in each of them.
    static func framesAfterAKey(on root: LayoutRootView, _ screen: ScreenContentView, host: PaneHostView, picture: NSView) -> KeyInMove {
        var result = KeyInMove()
        func leading() -> CGFloat { screen.convert(picture.frame, from: picture.superview).minX }
        var last = (picture: leading(), pane: host.frame)
        var moving = true
        while result.frames < 240, moving || Motion.inFlight(screen) {
            moving = root.advanceFrame(Motion.dt)
            root.layoutSubtreeIfNeeded()
            result.frames += 1
            let now = (picture: leading(), pane: host.frame)
            let edges = max(abs(now.pane.minX - last.pane.minX), abs(now.pane.maxX - last.pane.maxX))
            let went = abs(now.picture - last.picture)
            if went > edges + 1 {
                result.jumps.append("frame \(result.frames): the picture's leading edge went \(went) points, an edge of its pane at most \(edges)")
            }
            if result.end == nil, !Motion.inFlight(screen) {
                result.end = result.frames
                result.springsAtEnd = host.isOnLayoutSpring
            }
            last = now
        }
        return result
    }

    /// Display frames until nothing moves (at most 2 s of them).
    static func rest(_ root: LayoutRootView) {
        var count = 0
        while root.advanceFrame(Motion.dt), count < 240 { count += 1 }
    }

    /// Content that its pane's host holds whole in a key resize (the hold of a chat with its tools in the tab row).
    /// The right pane is split, and in the frame that shows the split a key moves the divider at its leading edge:
    /// that edge moves two times as far as its trailing edge. The old picture goes no farther than its pane's edges
    /// in each frame, and after the key's landing the content fills its pane.
    @Test func aResizeKeyInAMovesHoldLeavesTheOldPictureAtItsCornerWhenTheMoveEnds() throws {
        let (harness, screen) = try Self.rested(at: Self.nativeBesideAPane)
        defer { harness.window.closeAfterTest() }
        let landing = AllKinds.Landing()
        harness.root.context.afterCommit = { [landing] in landing.work.append($0) }
        let host = try #require(Motion.hosts(of: screen)[Commit.right], "SETUP: the right pane does not show")
        let before = host.content.frame.size
        let sizes = harness.provider.contents[Commit.right]?.sizes.count ?? 0

        harness.model.apply(screens: Self.rightPaneSplit)
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Motion.dt)
        try #require(Motion.hosts(of: screen)[Commit.right] === host, "SETUP: the right pane has another host after the split")
        try #require(Motion.inFlight(screen) && host.holdsContentForMove, "SETUP: the split's old pane is not held in a move")
        try #require(Self.near(host.content.frame.size, before), "SETUP: the held content is \(host.content.frame.size); it was \(before)")

        try #require(PaneResize.press(Commit.left, .left, model: harness.model, view: harness.root), "SETUP: the resize key was refused")
        let shown = Self.framesAfterAKey(on: harness.root, screen, host: host, picture: host.content)
        let end = try #require(shown.end, "SETUP: the move did not end in \(shown.frames) frames")
        try #require(shown.springsAtEnd, "SETUP: the key's spring ended before the move did (frame \(end) of \(shown.frames)): no key hold moves at the move's end")
        #expect(shown.jumps.isEmpty,
                "after a key in a move's hold the old picture jumped in \(shown.jumps.count) of \(shown.frames) frames (the move ended in frame \(end)): \(shown.jumps.prefix(3))")

        // What the key's landing leaves for after its commit: the content takes its pane's size.
        let release = landing.work
        landing.work.removeAll()
        for work in release { work() }
        harness.root.layoutSubtreeIfNeeded()
        #expect(!host.holdsContentForMove, "after the key's landing the pane holds its content at the size of before the split")
        #expect(host.content.frame == host.clipView.bounds, "after the key's landing the content is \(host.content.frame) in a clip of \(host.clipView.bounds)")
        #expect(host.content.frame.width < before.width - 1, "after the key's landing the content is \(host.content.frame.size), no narrower than the \(before) before the split")
        let took = (harness.provider.contents[Commit.right]?.sizes.count ?? 0) - sizes
        #expect(took == 1, "from the split to after the key's landing the content took \(took) sizes; it takes its pane's size one time")
    }

    /// Each pane's content is the app's pane content view: the right pane shows `page`, each other pane a page's view.
    final class KeyPanes: LayoutPaneContentProvider {
        let reveal: LaunchReveal = {
            let reveal = LaunchReveal()
            reveal.markAllReady()
            return reveal
        }()
        let page: NSView
        var views: [LayoutPaneID: PaneContentView] = [:]

        init(page: NSView) { self.page = page }

        func makeContentView(for pane: LayoutPaneID) -> NSView {
            let tabs = [TabItem(id: TabID("\(pane.rawValue)-tab0"), title: "Tab 0")]
            let view = PaneContentView(stripModel: TabStripModel(tabs: tabs, selectedID: tabs[0].id), reveal: reveal)
            view.show(pane == Commit.right ? page : Picture())
            views[pane] = view
            return view
        }
    }

    /// The docked Home's page, which its pane's content area holds in a key resize. The same split and the same key:
    /// the page goes no farther than its pane's edges in each frame, and after the key's landing it fills its area.
    @Test func aResizeKeyInAMovesHoldLeavesTheDockedHomesPageAtItsCornerWhenTheMoveEnds() throws {
        let (services, _) = HomeLaunchRevealTests.services()
        let page = AllKinds.page(.docked, services: services)
        defer { withExtendedLifetime(services) { (page.content as? HomeDockView)?.close() } }
        let provider = KeyPanes(page: page)
        let model = LayoutModel(screens: Self.nativeBesideAPane, activeScreenID: "s", focusedPane: Commit.left)
        let root = LayoutRootView(model: model, contentProvider: provider)
        root.context.reduceMotionOverride = false
        root.context.commitMotionOverride = true
        root.driver.isManual = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.closeAfterTest() }
        for _ in 0..<3 { root.layoutSubtreeIfNeeded() }
        Self.rest(root)
        let landing = AllKinds.Landing()
        root.context.afterCommit = { [landing] in landing.work.append($0) }

        let screen = try #require(root.screenViews.values.first, "SETUP: the root shows no screen")
        let host = try #require(Motion.hosts(of: screen)[Commit.right], "SETUP: the Home's pane does not show")
        let pane = try #require(provider.views[Commit.right], "SETUP: the Home's pane has no content view")
        let area = pane.contentHost
        try #require(page.window === window && !Motion.inFlight(screen), "SETUP: the pane does not show the docked Home's page at rest")
        try #require(page.holdsInKeyResize && pane.paneMotionHoldArea === area, "SETUP: the docked Home's page is not held in its pane's content area in a key resize")
        try #require(host.content.paneCommitMotionHolder === page, "SETUP: the docked Home's page is not the view that its pane's host holds in a move")
        let before = page.frame.size
        try #require(before.width > 100 && before.height > 100, "SETUP: the docked Home's page is \(before) before the split")

        model.apply(screens: Self.rightPaneSplit)
        root.syncWithModel()
        _ = root.advanceFrame(Motion.dt)
        try #require(Motion.hosts(of: screen)[Commit.right] === host, "SETUP: the Home's pane has another host after the split")
        try #require(Motion.inFlight(screen) && host.holdsContentForMove, "SETUP: the Home's pane is not held in a move")
        try #require(Self.near(page.frame.size, before), "SETUP: the held page is \(page.frame.size); it was \(before)")

        try #require(PaneResize.press(Commit.left, .left, model: model, view: root), "SETUP: the resize key was refused")
        let shown = Self.framesAfterAKey(on: root, screen, host: host, picture: page)
        let end = try #require(shown.end, "SETUP: the move did not end in \(shown.frames) frames")
        try #require(shown.springsAtEnd, "SETUP: the key's spring ended before the move did (frame \(end) of \(shown.frames)): no key hold moves at the move's end")
        #expect(shown.jumps.isEmpty,
                "after a key in a move's hold the Home page jumped in \(shown.jumps.count) of \(shown.frames) frames (the move ended in frame \(end)): \(shown.jumps.prefix(3))")

        // What the key's landing leaves for after its commit: the page takes its area's size.
        let release = landing.work
        landing.work.removeAll()
        for work in release { work() }
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        #expect(!host.holdsContentForMove, "after the key's landing the pane holds its content at the size of before the split")
        #expect(!area.isHolding, "the key's hold did not end at the landing")
        #expect(AllKinds.rect(page) == AllKinds.rect(area), "after the key's landing the docked Home's page is at \(AllKinds.rect(page)), its area at \(AllKinds.rect(area))")
        #expect(page.frame.width < before.width - 1, "after the key's landing the docked Home's page is \(page.frame.size), no narrower than the \(before) before the split")
    }
}
