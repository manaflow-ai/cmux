import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import Testing

/// `PaneCommitMotionTests`, what a pane that left the layout covers from the pass that shows its change.
///
/// A pane's content is cut by the rects of the panes in front of it (`ScreenContentView.panesAbove()`). A pane that a
/// close or a zoom took out covers nothing from the pass that shows that change: it hides in that pass, or the move
/// keeps it under each pane to its end. Two readings of `covers nothing` are in the code's history: the layout asks
/// the motion (`PaneCommitMotion.isUnderEachPane`), and a plain rule reads the pane's own state (`isLeaving`). The
/// first knows the turn before the pass too, where the screen still shows the pane in front. From the pass on they
/// must say the same, with the panes' move on and with it off: a pane that leaves while no motion keeps it is still
/// in front of no pane.
extension PaneCommitMotionTests {
    /// The Home's column, docked at the leading edge, and two strip columns beside it; with `pane`, that pane alone
    /// on its screen (a zoom). The Home's dock is pinned and takes tabs, as the app makes it.
    static func homeStrip(zoomedOn pane: PaneID? = nil) -> [LayoutScreen] {
        let home = DockColumn(edge: .left, mode: .docked, role: .agentChat, isPinned: true, allowsTabs: true)
        let columns = ScreenLayout.columns([
            LayoutColumn(id: "home", width: 0.3, root: .leaf("home"), dock: home),
            LayoutColumn(id: "c1", width: 0.6, root: .leaf("p1")),
            LayoutColumn(id: "c2", width: 0.6, root: .leaf("p2")),
        ])
        let layout = pane.map { ScreenLayout.splits(.leaf($0)) } ?? columns
        return [LayoutScreen(id: "s", name: "s", layout: layout, zoomed: pane != nil)]
    }

    /// A zoom of the pane beside the docked Home. The zoom takes the Home's column out of the screen, and the Home's
    /// pane is stacked above the strip's panes. The zoomed pane shows whole over the Home's place: no mask cuts it in
    /// the frame that shows the zoom, in a frame of the move or after the motion's end. `moves` false: the zoomed pane
    /// has a page's stand-in in its content area (a browser), so the zoom shows in one frame and no later pass comes
    /// to cut the pane again.
    @Test(arguments: [true, false])
    func aZoomBesideTheDockedHomeShowsItsPaneWholeOverTheHomesPlace(moves: Bool) throws {
        let harness = Commit.Harness(Self.homeStrip(), focused: "p1", holds: false)
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let rest = Self.hosts(of: screen)
        let place = try #require(rest["home"]?.frame, "SETUP: the Home's pane does not show at rest")
        let all = Self.area(place)
        try #require(rest.count == 3 && all > 1, "SETUP: the screen does not rest with its 3 panes: \(rest.mapValues(\.frame))")
        try #require(place.minX < (rest["p1"]?.frame.minX ?? 0), "SETUP: the Home's pane at \(place) is not at the leading edge")
        if !moves { try #require(Self.putAPage(over: "p1", harness), "SETUP: the pane that zooms has no content") }

        harness.model.apply(screens: Self.homeStrip(zoomedOn: "p1"))
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        let host = try #require(harness.root.context.hosts["p1"], "SETUP: the zoomed pane has no host")
        #expect(Self.inFlight(screen) == moves, "SETUP: the zoomed pane \(moves ? "has no move" : "has a move") on its layer")

        let cuts = Self.cuts(of: host, harness, screen)
        #expect(cuts.first == nil, "the frame that shows the zoom cuts the zoomed pane: \(cuts.first ?? "")")
        #expect(cuts.moving.isEmpty, "\(cuts.moving.count) of the \(cuts.frames) frames of the move cut the zoomed pane: \(cuts.moving.first ?? "")")
        #expect(cuts.after.isEmpty, "after the motion's end the zoomed pane is cut: \(cuts.after)")

        let shown = Self.hosts(of: screen)
        #expect(Set(shown.keys) == ["p1"], "the zoomed state shows these panes: \(shown.keys.sorted())")
        let seen = Self.area(of: place, shownBy: host)
        #expect(seen >= 0.9 * all, "in the zoomed state the zoomed pane shows in \(seen) pt2 of the \(all) pt2 of the Home's place \(place): the rest shows no pane")
    }

    // MARK: The two readings from the pass on

    /// The rects that cover each pane host of `screen` by the plain rule: a pane that shows, and that did not leave
    /// the layout, covers the panes behind it in the order of the screen's views. The same walk as
    /// `ScreenContentView.panesAbove()`, with the pane's own state in the place of the motion's answer.
    static func coversByThePlainRule(_ screen: ScreenContentView) -> [ObjectIdentifier: [CGRect]] {
        var covers: [ObjectIdentifier: [CGRect]] = [:]
        var front: [CGRect] = []
        for case let host as PaneHostView in screen.subviews.reversed() {
            let overlapping = front.filter { $0.intersection(host.frame).width > 0.5 && $0.intersection(host.frame).height > 0.5 }
            if !overlapping.isEmpty { covers[ObjectIdentifier(host)] = overlapping.reversed() }
            guard !host.isHidden, !host.isLeaving, host.alphaValue > 0.99 else { continue }
            front.append(screen.floatState.cards[host.pane]?.cardFrame ?? host.frame)
        }
        return covers
    }

    /// The pane hosts of `screen` that left the layout and still show.
    static func leaving(on screen: ScreenContentView) -> [PaneHostView] {
        screen.subviews.compactMap { $0 as? PaneHostView }.filter { $0.isLeaving && !$0.isHidden }
    }

    /// What differs between the two readings on `screen` now; empty: they say the same.
    static func readingsDiffer(on screen: ScreenContentView) -> [String] {
        var faults: [String] = []
        if screen.frameInput.changeIsUnshown { faults.append("a change of the screen still waits for its pass") }
        for host in leaving(on: screen) where !screen.zoomDim.motion.isUnderEachPane(host, unshown: screen.frameInput.changeIsUnshown) {
            faults.append("the pane \(host.pane) left the layout and the motion says that it is in front of a pane")
        }
        if screen.panesAbove() != coversByThePlainRule(screen) { faults.append("the covers are not those of the plain rule") }
        return faults
    }

    /// An act that takes panes out of the layout, and whether the panes move at it.
    struct Left: CustomTestStringConvertible, Sendable {
        let act: String
        let moves: Bool
        var testDescription: String { "\(act), the panes' move \(moves ? "on" : "off")" }
    }

    nonisolated static let lefts = [
        Left(act: "zoom", moves: true), Left(act: "close", moves: true),
        Left(act: "zoom", moves: false), Left(act: "close", moves: false),
    ]

    /// A zoom of the pane beside the docked Home (it takes the Home's pane and the other strip pane out), and a close
    /// of the Home's column. In the frame that shows the act, in each later frame of the move, and in the frame that
    /// ends the motion and the 2 frames after it: each pane that left and still shows is in front of no pane by the
    /// motion's answer, and the covers that the layout reads are those of the plain rule. With the panes' move on the
    /// frame that shows the act still shows a pane that left (so the row reads a case). With the move off no pane
    /// that left shows after that frame: each one hid in the pass, and no motion keeps a list of them.
    @Test(arguments: lefts)
    func fromThePassThatShowsAnActAPaneThatLeftIsInFrontOfNoPane(_ left: Left) throws {
        let harness = Commit.Harness(Self.homeStrip(), focused: "p1", holds: false)
        defer { harness.window.closeAfterTest() }
        if left.moves {
            Self.movePanes(harness)
        } else {
            harness.root.context.commitMotionOverride = false
        }
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        try #require(Self.hosts(of: screen).count == 3 && Self.leaving(on: screen).isEmpty, "SETUP: the screen does not rest with its 3 panes")
        try #require(Self.readingsDiffer(on: screen).isEmpty, "SETUP: at rest the two readings differ: \(Self.readingsDiffer(on: screen))")

        let strip = ScreenLayout.columns([LayoutColumn(id: "c1", width: 0.6, root: .leaf("p1")), LayoutColumn(id: "c2", width: 0.6, root: .leaf("p2"))])
        harness.model.apply(screens: left.act == "zoom" ? Self.homeStrip(zoomedOn: "p1") : [LayoutScreen(id: "s", name: "s", layout: strip, zoomed: false)])
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        let first = Self.leaving(on: screen).map(\.pane)
        if left.moves {
            try #require(Self.inFlight(screen) && !first.isEmpty, "SETUP: the frame that shows the \(left.act) moves no pane over a pane that left: \(first)")
        } else {
            #expect(!Self.inFlight(screen) && first.isEmpty, "with the panes' move off the frame that shows the \(left.act) still shows panes that left: \(first)")
        }
        #expect(Self.readingsDiffer(on: screen).isEmpty, "in the frame that shows the \(left.act): \(Self.readingsDiffer(on: screen))")

        var frames = 0
        while Self.inFlight(screen), frames < Commit.frames {
            _ = harness.root.advanceFrame(Self.dt)
            frames += 1
            #expect(Self.readingsDiffer(on: screen).isEmpty, "frame \(frames + 1) of the \(left.act): \(Self.readingsDiffer(on: screen))")
        }
        for extra in 0...2 {
            if extra > 0 { _ = harness.root.advanceFrame(Self.dt) }
            #expect(Self.leaving(on: screen).isEmpty, "\(extra) frames after the motion's end these panes that left still show: \(Self.leaving(on: screen).map(\.pane))")
            #expect(Self.readingsDiffer(on: screen).isEmpty, "\(extra) frames after the motion's end: \(Self.readingsDiffer(on: screen))")
        }
    }
}
