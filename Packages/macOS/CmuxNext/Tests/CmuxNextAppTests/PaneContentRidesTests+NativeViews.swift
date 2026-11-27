import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import QuartzCore
import Testing

/// `PaneContentRidesTests`, the app's native views that fill a pane: the native Home view of one conversation (the
/// Chief's tab, a Home conversation as a tab), the view of a remote terminal that is not attached, the notice of a chat
/// that runs on another machine and the notice of a tab that another window shows. Each is of the pages' kind, so a
/// pane that shows one rides its move and its host holds the view while the pane gets smaller: no kind of a tab's
/// content makes an act show in one frame.
extension PaneContentRidesTests {
    nonisolated static let nativeViews = [
        "the native Home view", "a remote terminal that is not attached", "a chat on another machine", "a tab that another window shows",
    ]

    /// The app's own view of that name, and what has to live as long as the view.
    static func nativeView(_ name: String) -> (view: NSView, keeping: [Any]) {
        switch name {
        case "the native Home view":
            let (services, _) = HomeLaunchRevealTests.services()
            return (HomeHostView(services: services, conversation: "conv_local"), [services])
        case "a remote terminal that is not attached":
            return (RemoteTerminalPlaceholderView(frame: .zero), [])
        case "a chat on another machine":
            return (AgentTabElsewhereView(machine: "studio"), [])
        default:
            return (TabShownElsewhereView(message: "Shown in another window", action: "Show Here") {}, [])
        }
    }

    /// Gives `content` what the app's pane content has: one content area that fills it, and in it `view`, which fills
    /// the area.
    static func show(_ view: NSView, in content: NSView) {
        let area = PaneContentAreaView(frame: content.bounds)
        area.autoresizingMask = [.width, .height]
        view.frame = area.bounds
        view.autoresizingMask = [.width, .height]
        area.addSubview(view)
        content.addSubview(area)
    }

    /// The app's own content area with the app's own view as the top view that fills it: the view is of the pages'
    /// kind, the pane's content rides, and the view is the one that keeps its own picture in a move.
    @Test(arguments: nativeViews)
    func aPaneThatShowsANativeViewRidesAndTheViewKeepsItsOwnPicture(_ name: String) {
        _ = NSApplication.shared
        let made = Self.nativeView(name)
        let view = made.view
        withExtendedLifetime(made.keeping) {
            #expect(Self.isOfThePagesKind(type(of: view)), "\(name) is not of the pages' kind: an act on its pane shows in one frame")
            let content = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
            Self.show(view, in: content)
            #expect(content.paneRidesCommitMotion, "a pane that shows \(name) does not ride: an act that changes its pane shows in one frame, for each pane of the act")
            #expect(content.paneCommitMotionHolder === view, "\(name) is not the view that keeps its pane's old picture in a move")
            // A view that left its pane (its tab is not shown) stops no ride and gives none.
            view.removeFromSuperview()
            #expect(!content.paneRidesCommitMotion && content.paneCommitMotionHolder == nil, "\(name) left its pane, and the pane rides or holds")
        }
    }

    /// Two panes side by side in one column, then the right one split to the right: the left pane gets narrower.
    static var nativeBesideAPane: [LayoutScreen] {
        columns([LayoutColumn(id: "c", width: 1, root: .split(SplitID("s"), axis: .horizontal, ratio: 0.5, a: .leaf(Commit.left), b: .leaf(Commit.right)))])
    }

    static var nativeBesideASplitPane: [LayoutScreen] {
        let halves = SplitNode.split(SplitID("new"), axis: .horizontal, ratio: 0.5, a: .leaf(Commit.right), b: .leaf(Commit.added))
        return columns([LayoutColumn(id: "c", width: 1, root: .split(SplitID("s"), axis: .horizontal, ratio: 0.34, a: .leaf(Commit.left), b: halves))])
    }

    /// The Chief's tab (the native Home view of one conversation) in the left pane, and a split of the pane beside it
    /// that makes its pane narrower: the act moves its panes, the native view keeps the size it had in each frame of
    /// the move under its pane's moving clip, and has its pane's size after the frame that ends the move.
    @Test func aSplitBesideTheNativeHomeViewMovesItsPaneAndTheViewIsHeldToTheEnd() throws {
        let (services, _) = HomeLaunchRevealTests.services()
        let home = HomeHostView(services: services, conversation: "conv_local")
        let harness = Commit.Harness(Self.nativeBesideAPane, focused: Commit.left, holds: true)
        defer { withExtendedLifetime(services) { harness.window.closeAfterTest() } }
        Motion.movePanes(harness)
        Commit.rest(harness)
        let left = try #require(harness.provider.contents[Commit.left]), right = try #require(harness.provider.contents[Commit.right])
        Self.show(home, in: left)
        _ = Self.showPicture(in: right)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        try #require(!Motion.inFlight(screen), "SETUP: the screen does not rest before the act")
        let host = try #require(Motion.hosts(of: screen)[Commit.left], "SETUP: the native Home view's pane does not show")
        let was = host.frame, before = home.frame.size
        try #require(before.width > 100 && before.height > 100, "SETUP: the native Home view is \(before) before the act")
        try #require(left.paneCommitMotionHolder === home, "the native Home view is not the view that its pane's host holds in a move")

        harness.model.apply(screens: Self.nativeBesideASplitPane)
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Motion.dt)

        try #require(Motion.hosts(of: screen)[Commit.left] === host, "SETUP: the native Home view's pane has another host after the act")
        try #require(host.frame.width < was.width - 1, "SETUP: the pane is \(host.frame.width) wide after the act; it was \(was.width)")
        try #require(Motion.inFlight(screen), "no pane moves: a split beside the native Home view's pane shows in one frame")
        let layer = try #require(host.layer)
        let move = Motion.move(of: layer)
        #expect(move.moves, "the native Home view's pane went from \(was) to \(host.frame) with no move on its layer")
        #expect(host.holdsContentForMove, "the native Home view's pane gets smaller and its host does not hold the view")
        var tick = 0
        while Motion.inFlight(screen), tick < Commit.frames {
            #expect(Self.near(home.frame.size, before), "frame \(tick): the native Home view is \(home.frame.size) while its pane moves; it was \(before)")
            _ = harness.root.advanceFrame(Motion.dt)
            tick += 1
        }
        Commit.rest(harness)
        #expect(!host.holdsContentForMove, "after the motion's end the pane holds the native Home view at the old size")
        #expect(host.content.frame == host.clipView.bounds, "after the motion's end the pane's content is \(host.content.frame) in a clip of \(host.clipView.bounds)")
        #expect(home.frame.width < before.width - 1, "after the motion's end the native Home view is \(home.frame.size), no narrower than the \(before) before the act")
        #expect(Self.near(home.frame.size, left.frame.size), "after the motion's end the native Home view is \(home.frame.size) in a pane content of \(left.frame.size)")
    }
}
