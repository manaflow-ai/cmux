import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import Testing

/// The test double of `PaneLayoutCommitTests` rides its pane's move, as a terminal's host does: its content has its
/// final size in the frame that shows a change.
extension PaneLayoutCommitTests.Content: PaneCommitMotionRiding {}

/// `PaneCommitMotionTests`, who moves: the product's default, a fixture that pins the motion, which pane content
/// rides, an act with a pane that does not ride, and a content that keeps its own old picture.
extension PaneCommitMotionTests {
    /// A pane content as the app builds it: a container with one content area that fills it.
    static func content() -> (view: NSView, area: PaneContentAreaView) {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let area = PaneContentAreaView(frame: view.bounds)
        view.addSubview(area)
        return (view, area)
    }

    /// With no pin of a test, the pane animations setting at its default and Reduce Motion off, a split moves its
    /// panes: the motion is on in the product's default.
    @Test func byDefaultASplitMovesItsPanes() throws {
        let begun = try Self.begin(Self.split, off: "no pin")
        defer { begun.harness.window.closeAfterTest() }
        let context = begun.harness.root.context
        try #require(context.reduceMotionOverride == nil && context.commitMotionOverride == nil, "SETUP: the context has a pin")
        #expect(context.animatesPaneLayout, "SETUP: the pane animations setting is not at its default")
        let on = !context.reduceMotion && context.animatesPaneLayout
        #expect(context.movesPanesAtCommit == on, "with no pin the switch is \(context.movesPanesAtCommit); Reduce Motion is \(context.reduceMotion)")
        #expect(Self.inFlight(begun.screen) == on, "with no pin, the pane animations on and Reduce Motion \(context.reduceMotion) a split's panes move: \(!on)")
    }

    /// A fixture that pins Reduce Motion to off and does not ask for the motion gets none: a split shows in one
    /// frame, as before the motion. Each fixture that counts the frames of a change stands on this.
    @Test func aFixtureThatPinsTheMotionGetsNoMoveUnlessItAsks() throws {
        let (before, after) = Commit.layouts(of: Commit.Change(name: Self.split.name, holds: false))
        let harness = Commit.Harness(before, focused: Commit.left, holds: false)
        defer { harness.window.closeAfterTest() }
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let context = harness.root.context
        try #require(context.reduceMotionOverride == false && context.commitMotionOverride == nil, "SETUP: the fixture does not pin the motion as the old fixtures do")
        #expect(!context.movesPanesAtCommit, "a fixture that pins Reduce Motion to off and asks for no motion has the switch on")
        harness.model.apply(screens: after)
        let new = Commit.Rest(harness.model.screens, in: screen, style: context.style)
        harness.root.syncWithModel()
        let asks = harness.root.advanceFrame(Self.dt)
        #expect(new.isShown(by: Commit.shown(screen)), "the first frame after the split does not show its layout alone: \(Commit.shown(screen).panes)")
        #expect(!Self.inFlight(screen), "a pane has a move on its layer in a fixture that did not ask for the motion")
        #expect(!asks || !harness.root.advanceFrame(Self.dt) || !harness.root.advanceFrame(Self.dt), "frames run on after a split with the motion off")
    }

    /// This pane rides: the app's own content area with the app's own terminal host as the top view that fills it.
    /// A view of another kind that fills the area over the terminal stops the ride; a hidden one, and one that
    /// covers a part of the area, do not.
    @Test func aPaneWhoseAreaShowsATerminalRides() {
        let (view, area) = Self.content()
        let terminal = TerminalHostView()
        terminal.frame = area.bounds
        area.addSubview(terminal)
        #expect(view.paneRidesCommitMotion, "a terminal's host fills the pane's content area and the pane does not ride")
        let cover = NSView(frame: area.bounds)
        area.addSubview(cover)
        #expect(!view.paneRidesCommitMotion, "a view of another kind fills the area over the terminal and the pane rides")
        cover.isHidden = true
        #expect(view.paneRidesCommitMotion, "a hidden view over the terminal stops the ride")
        cover.isHidden = false
        cover.frame = CGRect(x: 0, y: 0, width: area.bounds.width, height: 30)
        #expect(view.paneRidesCommitMotion, "a bar over a part of the terminal stops the ride")
        terminal.isHidden = true
        #expect(!view.paneRidesCommitMotion, "the area shows no terminal, it waits for none, and the pane rides")
    }

    /// A split's new terminal pane shows only its ground in the frame of its key: its area waits for the terminal.
    /// It rides. An area that shows nothing and waits for no terminal does not.
    @Test func aPaneThatWaitsForItsTerminalRides() {
        let (view, area) = Self.content()
        #expect(!view.paneRidesCommitMotion, "an area that shows nothing and waits for no terminal rides")
        area.waitingGround = CGColor(gray: 0.1, alpha: 1)
        #expect(view.paneRidesCommitMotion, "an area that waits for its terminal does not ride")
        #expect(!NSView(frame: view.frame).paneRidesCommitMotion, "a view of no known kind rides")
    }

    /// An act whose panes do not all ride shows in one frame. The pane whose rect changes has a content area with a
    /// view of another kind on top (a page's stand-in): it is the pane that gives its room at a split, and the pane
    /// that takes the room at a close. No pane moves, the frame that shows the act has its layout alone (the closed
    /// pane is hidden in it), and no frame runs on.
    @Test(arguments: [PaneCommitMotionTests.split, PaneCommitMotionTests.close])
    func anActWithAPaneThatDoesNotRideShowsInOneFrame(_ act: Act) throws {
        var placed = false
        let begun = try Self.begin(act) { harness in
            guard let content = harness.provider.contents[Commit.left] else { return }
            let area = PaneContentAreaView(frame: content.bounds)
            area.autoresizingMask = [.width, .height]
            let page = NSView(frame: area.bounds)
            page.autoresizingMask = [.width, .height]
            area.addSubview(page)
            content.addSubview(area)
            placed = true
        }
        defer { begun.harness.window.closeAfterTest() }
        try #require(placed, "SETUP: the pane has no content")
        let rides = begun.harness.provider.contents[Commit.left]?.paneRidesCommitMotion
        try #require(rides == false, "SETUP: a pane whose area shows a view of another kind rides: \(String(describing: rides))")
        #expect(begun.harness.root.context.movesPanesAtCommit, "SETUP: the motion is off")
        #expect(begun.new.isShown(by: Commit.shown(begun.screen)), "the first frame after the act does not show its layout alone: \(Commit.shown(begun.screen).panes)")
        #expect(!Self.inFlight(begun.screen), "a pane has a move on its layer in an act with a pane that does not ride")
        #expect(!begun.harness.root.advanceFrame(Self.dt) || !begun.harness.root.advanceFrame(Self.dt), "frames run on after an act that shows in one frame")
    }

    /// A content that keeps its own old picture and rides, in a content area of the double's view.
    final class Holder: NSView, PaneCommitMotionHolding, PaneCommitMotionRiding {
        weak var content: PaneLayoutCommitTests.Content?
        var log: [String] = []
        var paneCommitMotionHoldKind: PaneCommitMotionHoldKind { .ownPicture }
        func beginPaneCommitMotionHold() { log.append("begin at \(content?.sizes.count ?? -1) sizes") }
        func endPaneCommitMotionHold() { log.append("end") }
    }

    /// A split's old pane gets smaller. A content that keeps its own old picture hears the start of its hold before
    /// its pane's content hears a size, gets no ground strip, and hears the end one time, in the frame that ends the
    /// motion.
    @Test func aContentThatKeepsItsOwnPictureHearsItsHoldAroundTheMotion() throws {
        let holder = Holder()
        var sizes = -1
        let begun = try Self.begin(Self.split) { harness in
            guard let content = harness.provider.contents[Commit.left] else { return }
            let area = PaneContentAreaView(frame: content.bounds)
            area.autoresizingMask = [.width, .height]
            holder.frame = area.bounds
            holder.autoresizingMask = [.width, .height]
            holder.content = content
            area.addSubview(holder)
            content.addSubview(area)
            sizes = content.sizes.count
        }
        defer { begun.harness.window.closeAfterTest() }
        try #require(sizes >= 0, "SETUP: the pane has no content")
        try #require(Self.inFlight(begun.screen), "no pane moves: the split shows in one frame")
        #expect(holder.log == ["begin at \(sizes) sizes"], "in the frame that shows the split the holder heard \(holder.log)")
        let host = try #require(Self.hosts(of: begun.screen)[Commit.left])
        let strips = (host.layer?.sublayers ?? []).filter { $0.name == Self.groundStrip }
        #expect(strips.isEmpty, "a content that keeps its own picture has a ground strip beside it")
        var frame = 1
        while Self.inFlight(begun.screen), frame < Commit.frames {
            #expect(holder.log.count == 1, "frame \(frame) of the motion: the holder heard \(holder.log)")
            _ = begun.harness.root.advanceFrame(Self.dt)
            frame += 1
        }
        #expect(holder.log == ["begin at \(sizes) sizes", "end"], "after the motion's end the holder heard \(holder.log)")
    }
}
