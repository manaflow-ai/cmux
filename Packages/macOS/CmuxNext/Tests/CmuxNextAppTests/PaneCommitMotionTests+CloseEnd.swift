import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, the end of a close's move.
///
/// At the end of a close's move the pane that the close took out hides, and the panes that went over it lose the
/// ground that covered it. The hide is first, and both are in one transaction: no frame can show the closed pane with
/// no pane over it.
extension PaneCommitMotionTests {
    /// Whether `host` has the ground that the motion gives a pane that moves: a copy of the window's picture, or the
    /// window's plain colour on its layer.
    static func hasGround(_ host: PaneHostView) -> Bool {
        !pictures(on: host).isEmpty || host.layer?.backgroundColor != nil
    }

    nonisolated static let hideScenes = ["a picture, 2 panes", "a picture, 6 panes", "opaque, 3 panes"]

    /// A close over a window's picture and in an opaque window, with the layout's own host and its own way out for a
    /// closed pane (`LayoutViewContext.retire`, `hideRetiredShown`). The closed pane stays under the panes that take
    /// its room, and each of those has a ground that covers it. In the turn that hides the closed pane each of them
    /// still has that ground, and the closed pane is still under them: the hide is first, the cover goes after it.
    /// After the motion's end no pane has the motion's ground.
    @Test(arguments: hideScenes)
    func atACloseTheClosedPaneHidesBeforeItsCoverGoes(_ scene: String) throws {
        let harness: Commit.Harness, screen: ScreenContentView
        if scene.hasPrefix("a picture") {
            let over = try Self.overPicture("close", panes: scene.contains("6") ? 6 : 2)
            (harness, screen) = (over.harness, over.screen)
        } else {
            let begun = try Self.begin(Self.close)
            (harness, screen) = (begun.harness, begun.screen)
        }
        defer { harness.window.closeAfterTest() }
        let hosts = Self.paneHosts(screen).filter { !$0.isHidden }
        let gone = try #require(hosts.first { $0.isLeaving }, "SETUP: the close keeps no pane on the screen for its move")
        let covers = hosts.filter { !$0.isLeaving && Self.moves($0) }
        let under = gone.layer?.zPosition ?? 0
        try #require(!covers.isEmpty && covers.allSatisfy { Self.hasGround($0) && ($0.layer?.zPosition ?? 0) > under },
                     "SETUP: the \(covers.count) panes that take the closed pane's room do not each have a ground and a place over it")
        let probe = HideProbe()
        probe.gone = gone
        probe.covers = covers
        gone.content.addSubview(probe)
        let end = Self.toTheEnd(harness, screen)
        try #require(!Self.inFlight(screen) && end.ticks > 1, "SETUP: the close's move had \(end.ticks) frames")
        #expect(gone.isHidden, "after the motion's end the closed pane still shows")
        #expect(probe.hides.count == 1, "the closed pane's content heard \(probe.hides.count) hides in the move, not 1")
        if let hide = probe.hides.first {
            #expect(hide.hidden && hide.covered == covers.count && hide.z == under,
                    "in the turn that hides the closed pane (hidden: \(hide.hidden)), \(hide.covered) of the \(covers.count) panes over it still have their ground and its zPosition is \(hide.z) (\(under) in the move): the cover went first")
        }
        #expect(covers.allSatisfy { !Self.hasGround($0) }, "after the motion's end a pane keeps the motion's ground")
    }
}

/// A view in a closed pane's content. In the turn that hides it (its own hide or an ancestor's) it reads whether the
/// closed pane's host is hidden, how many of the panes over it still have their ground, and the host's `zPosition`.
private final class HideProbe: NSView {
    weak var gone: PaneHostView?
    var covers: [PaneHostView] = []
    private(set) var hides: [(hidden: Bool, covered: Int, z: CGFloat)] = []

    override func viewDidHide() {
        super.viewDidHide()
        let covered = covers.filter { PaneCommitMotionTests.hasGround($0) }.count
        hides.append((hidden: gone?.isHidden ?? false, covered: covered, z: gone?.layer?.zPosition ?? 0))
    }
}
