import AppKit
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// `PaneContentRidesTests`, the hold itself: where the held content is under its pane's clip, what the content hears
/// around its one resize, and the changes that hold nothing (a close of the held pane, a pane that grows, the motion
/// off).
extension PaneContentRidesTests {
    /// The app's views of the pages' kind: a browser pane's view and a chat's view. Each is the view that fills its
    /// pane's content area, so its pane rides a move and its host holds it.
    @Test func theAppsBrowserViewAndChatViewAreOfThePagesKind() {
        let kinds: [NSView.Type] = [BrowserChromeView.self, AgentPaneView.self]
        for kind in kinds {
            #expect(Self.isOfThePagesKind(kind), "\(kind) is not of the pages' kind: an act on its pane shows in one frame")
        }
        #expect(!Self.isOfThePagesKind(NSView.self), "each view is of the pages' kind")
    }

    static func isOfThePagesKind(_ kind: NSView.Type) -> Bool { kind is any PaneCommitMotionPicture.Type }

    /// While its pane moves to a smaller rect the held content is at its pane's top leading corner, at the size it
    /// had. The clip inside the pane cuts in each frame, and its layer has the pane's change of size as a move: it
    /// starts at the size the content has, with no change of its corner, so the old picture is whole under the edge
    /// that moves and the pane's inset and round corners stay. After the motion's end the clip has no move and the
    /// content fills it.
    @Test(arguments: splits)
    func heldContentIsWholeAtItsPanesTopLeadingCornerUnderThePanesOwnClip(_ act: Motion.Act) throws {
        let begun = try Self.begin(act)
        defer { begun.harness.window.closeAfterTest() }
        let harness = begun.harness, screen = begun.screen
        let pane = try #require(begun.smaller.first, "SETUP: the act makes no pane smaller")
        let host = try #require(Motion.hosts(of: screen)[pane], "\(pane) does not show in the frame that shows the act")
        let layer = try #require(host.layer), clip = host.clipView, cut = try #require(clip.layer)
        let before = try #require(begun.contents[pane]), was = try #require(begun.motion.was[pane])
        try #require(Motion.inFlight(screen), "no pane moves: the act shows in one frame")
        // The pane's layer starts where the pane showed, and the content is at the layer's corner: so is its picture.
        #expect(Commit.near(Motion.move(of: layer).start, was), "\(pane)'s move starts at \(Motion.move(of: layer).start), not where the pane showed: \(was)")
        // The clip's layer starts at the size the content keeps, at the clip's own corner, and goes to the clip's size.
        let opening = Motion.move(of: cut)
        #expect(opening.moves, "the clip inside \(pane) has no move: it cuts the held content at the pane's new size in the frame that shows the act")
        #expect(opening.issues.isEmpty, "the clip inside \(pane): \(opening.issues)")
        #expect(Self.near(opening.start.size, before), "the clip inside \(pane) starts at \(opening.start.size); the held content is \(before)")
        #expect(Commit.near(CGRect(origin: opening.start.origin, size: opening.end.size), opening.end),
                "the clip inside \(pane) starts at \(opening.start.origin) and ends at \(opening.end.origin): its corner moves in its pane")
        #expect(Commit.near(opening.end, cut.frame), "the clip inside \(pane) ends at \(opening.end), not at its place \(cut.frame)")
        var tick = 0
        while Motion.inFlight(screen), tick < Commit.frames {
            let content = host.content.frame
            #expect(host.content.superview === clip, "frame \(tick): the held content is not in its pane's clip")
            #expect(content.origin == clip.bounds.origin, "frame \(tick): the held content is at \(content.origin) in its pane's clip, not at its corner")
            #expect(Self.near(content.size, before), "frame \(tick): the held content is \(content.size); it was \(before)")
            #expect(content.width >= clip.bounds.width && content.height >= clip.bounds.height,
                    "frame \(tick): the held content \(content.size) does not cover its pane's content rect \(clip.bounds.size)")
            #expect(cut.masksToBounds, "frame \(tick): the clip inside the pane does not cut: the pane's inset and corners are gone")
            #expect(Motion.move(of: cut).moves, "frame \(tick): the clip inside the pane has no move while its pane moves")
            _ = harness.root.advanceFrame(Motion.dt)
            tick += 1
        }
        #expect(!Motion.move(of: cut).moves, "after the motion's end the clip inside the pane has a move")
        #expect(cut.masksToBounds, "after the motion's end the clip inside the pane does not cut")
        #expect(host.content.frame == clip.bounds, "after the motion's end the content is \(host.content.frame) in a clip of \(clip.bounds)")
    }

    /// The one resize at the motion's end comes between the two notices that a page knows: the size change its pane
    /// will rest at, then the size, then that the pane rests. Before that frame the page's view takes no size.
    @Test func theOneResizeAtTheMotionsEndComesBetweenItsTwoNotices() throws {
        let begun = try Self.begin(Motion.split)
        defer { begun.harness.window.closeAfterTest() }
        let harness = begun.harness, screen = begun.screen
        let picture = try #require(begun.pictures[Commit.left]), before = try #require(begun.contents[Commit.left])
        try #require(Motion.inFlight(screen), "no pane moves: the split shows in one frame")
        let heard = begun.heard[Commit.left] ?? 0
        var last = picture.log.count, tick = 1
        while Motion.inFlight(screen), tick < Commit.frames {
            last = picture.log.count
            _ = harness.root.advanceFrame(Motion.dt)
            tick += 1
        }
        let early = picture.log.dropFirst(heard).prefix(max(0, last - heard)), atEnd = Array(picture.log.dropFirst(last))
        #expect(!early.contains("size"), "the page's view took a size before the frame that ends the motion: \(Array(early))")
        #expect(atEnd == ["will rest", "size", "settled"], "in the frame that ends the motion the page's view heard \(atEnd)")
        let final = try #require(Motion.hosts(of: screen)[Commit.left]?.contentRect.size, "the pane does not show after the motion's end")
        let change = try #require(picture.rests.last, "the page's view heard no size change")
        #expect(Self.near(change, CGSize(width: final.width - before.width, height: final.height - before.height)),
                "the page's view heard a change of \(change); its pane went from \(before) to \(final)")
    }

    /// A split, and three frames later the close of the pane that the split halved, the one whose content is held:
    /// its content takes no size. The pane goes with the picture it had.
    @Test func theCloseOfAHeldPaneGivesItsContentNoSize() throws {
        let begun = try Self.begin(Motion.split, focused: Commit.right)
        defer { begun.harness.window.closeAfterTest() }
        let harness = begun.harness, screen = begun.screen
        let content = try #require(harness.provider.contents[Commit.left])
        try #require(Motion.inFlight(screen) && begun.took(Commit.left) == 0, "SETUP: the split's old pane is not held")
        for _ in 0..<3 { _ = harness.root.advanceFrame(Motion.dt) }

        let closed = Commit.screen(.split(SplitID("pair"), axis: .horizontal, ratio: 0.5, a: .leaf(Commit.added), b: .leaf(Commit.right)))
        harness.model.apply(screens: closed)
        let rest = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Motion.dt)
        _ = Motion.toTheEnd(harness, screen)
        Commit.rest(harness)

        let took = begun.took(Commit.left)
        #expect(took == 0, "the close of a held pane resized its content \(took) times: \(content.sizes.suffix(took))")
        #expect(rest.isShown(by: Commit.shown(screen)), "after the close the screen does not show the two panes that stay: \(Commit.shown(screen).panes)")
    }

    /// A page's view can leave its pane while that pane moves: its tab closes, or another pane takes its tab. The
    /// motion's end still reaches the pane host that held the content: that host has no held size after it, and its
    /// content has the pane's size, taken one time. The pane that took the view holds nothing.
    @Test(arguments: ["its tab closes", "another pane takes its tab"])
    func aPageThatLeavesAHeldPaneInTheMoveLeavesNoHeldSize(_ leave: String) throws {
        let begun = try Self.begin(Motion.split)
        defer { begun.harness.window.closeAfterTest() }
        let harness = begun.harness, screen = begun.screen
        let hosts = Motion.hosts(of: screen)
        let host = try #require(hosts[Commit.left], "the split's old pane does not show")
        let other = try #require(hosts[Commit.right], "the pane beside it does not show")
        let picture = try #require(begun.pictures[Commit.left])
        try #require(Motion.inFlight(screen) && host.clipView.moveHeldSize != nil, "SETUP: the split's old pane is not held")
        for _ in 0..<3 { _ = harness.root.advanceFrame(Motion.dt) }
        try #require(Motion.inFlight(screen), "SETUP: the motion ended before the page's view left its pane")

        if leave == "its tab closes" {
            picture.removeFromSuperview()
        } else {
            let area = try #require(begun.pictures[Commit.right]?.superview, "SETUP: the pane beside it shows no page")
            area.addSubview(picture)
        }
        _ = Motion.toTheEnd(harness, screen)
        Commit.rest(harness)

        #expect(host.clipView.moveHeldSize == nil, "\(leave): after the motion's end the pane keeps its content at the old size \(String(describing: host.clipView.moveHeldSize))")
        #expect(other.clipView.moveHeldSize == nil, "\(leave): after the motion's end the pane beside it holds its content")
        #expect(host.content.frame == host.clipView.bounds, "\(leave): after the motion's end the content is \(host.content.frame) in a clip of \(host.clipView.bounds)")
        #expect(begun.took(Commit.left) == 1, "\(leave): the pane's content took \(begun.took(Commit.left)) sizes; it takes its pane's size one time")
    }

    /// A split, and three frames later a zoom of another pane: the zoom covers the pane whose content is held and
    /// keeps it for the unzoom. Its content takes its pane's size one time, at the end of the hold, so the unzoom
    /// brings the pane back with its content at the pane's size and with no other resize.
    @Test func aZoomThatCoversAHeldPaneGivesItsContentItsPanesSizeOneTime() throws {
        let begun = try Self.begin(Motion.split, focused: Commit.right)
        defer { begun.harness.window.closeAfterTest() }
        let harness = begun.harness, screen = begun.screen
        let host = try #require(Motion.hosts(of: screen)[Commit.left], "the split's old pane does not show")
        try #require(Motion.inFlight(screen) && begun.took(Commit.left) == 0, "SETUP: the split's old pane is not held")
        for _ in 0..<3 { _ = harness.root.advanceFrame(Motion.dt) }

        harness.model.apply(screens: Commit.screen(.leaf(Commit.right), zoomed: true))
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Motion.dt)
        _ = Motion.toTheEnd(harness, screen)
        Commit.rest(harness)
        #expect(begun.took(Commit.left) == 1, "a zoom covered a held pane and its content took \(begun.took(Commit.left)) sizes")
        #expect(host.content.frame == host.clipView.bounds, "under the zoom the covered pane's content is \(host.content.frame) in a clip of \(host.clipView.bounds)")

        harness.model.apply(screens: Self.layouts(of: Motion.split).after)
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Motion.dt)
        _ = Motion.toTheEnd(harness, screen)
        Commit.rest(harness)
        let back = try #require(Motion.hosts(of: screen)[Commit.left], "after the unzoom the pane does not show")
        #expect(begun.took(Commit.left) == 1, "after the unzoom the pane's content took \(begun.took(Commit.left)) sizes from the split on")
        #expect(back.content.frame == back.clipView.bounds, "after the unzoom the pane's content is \(back.content.frame) in a clip of \(back.clipView.bounds)")
    }

    /// The turn of a second Cmd-Shift-Enter in the zoom's motion of a pane with a page's view changes nothing that
    /// shows: the pane that zooms still has its move, the same dim shows, and the pane that the zoom covers shows no
    /// ring over the pane that moves. The frame that shows the unzoom shows that ring, and the page's view keeps its
    /// size under its pane's move. At the unzoom's end the view has its pane's size again, by one resize from the key on.
    @Test func theTurnOfASecondKeyInAZoomsMotionOfAPageShowsNoCoveredPanesRing() throws {
        let begun = try Self.begin(Motion.zoom)
        defer { begun.harness.window.closeAfterTest() }
        let harness = begun.harness, screen = begun.screen
        for _ in 0..<2 { _ = harness.root.advanceFrame(Motion.dt) }
        try #require(Motion.inFlight(screen), "SETUP: the pane that zooms does not move three frames after the key")
        let dim = try #require(PaneZoomDimTests.dim(harness), "SETUP: no dim shows three frames into the zoom's move")
        let before = harness.provider.contents[Commit.left]?.sizes.count ?? 0

        harness.model.apply(screens: Self.layouts(of: Motion.zoom).before)
        harness.root.syncWithModel()
        #expect(PaneZoomDimTests.dim(harness)?.view === dim.view, "the second key's turn took the dim away before its change shows")
        #expect(Motion.inFlight(screen), "the second key's turn ended the pane's move before its change shows")
        let covered = try #require(harness.root.context.hosts[Commit.right], "the covered pane has no host after the second key")
        #expect(!covered.isHidden && covered.chrome.isHidden, "the covered pane's ring shows in the second key's turn, over the pane that still moves")

        _ = harness.root.advanceFrame(Motion.dt)
        #expect(harness.root.context.hosts[Commit.right]?.chrome.isHidden == false, "the covered pane's ring does not show in the frame that shows the unzoom")
        let early = (harness.provider.contents[Commit.left]?.sizes.count ?? 0) - before
        #expect(Motion.inFlight(screen) && early == 0, "in the frame that shows the unzoom the page's view took \(early) sizes, or its pane has no move")
        _ = Motion.toTheEnd(harness, screen)
        Commit.rest(harness)
        let host = try #require(Motion.hosts(of: screen)[Commit.left], "after the unzoom the pane that zoomed does not show")
        let took = (harness.provider.contents[Commit.left]?.sizes.count ?? 0) - before
        #expect(took == 1, "from the second key to the unzoom's end the page's view took \(took) sizes")
        #expect(host.content.frame == host.clipView.bounds, "after the unzoom the page's view is \(host.content.frame) in a clip of \(host.clipView.bounds)")
    }

    /// A pane that grows holds nothing: its content has its final size in the frame that shows the act, as with no
    /// move, and the clip inside the pane cuts.
    @Test func theContentOfAPaneThatGrowsHasItsFinalSizeInTheFrameThatShowsTheAct() throws {
        let begun = try Self.begin(Motion.close)
        defer { begun.harness.window.closeAfterTest() }
        let hosts = Motion.hosts(of: begun.screen)
        var grown = 0
        for (pane, rect) in begun.motion.new.panes {
            guard let old = begun.motion.old.panes[pane], rect.width > old.width + 1 || rect.height > old.height + 1 else { continue }
            grown += 1
            let host = try #require(hosts[pane], "\(pane) does not show in the frame that shows the act")
            #expect(begun.took(pane) == 1, "\(pane) grows and its content took \(begun.took(pane)) sizes in the frame that shows the act")
            #expect(host.content.frame == host.clipView.bounds, "\(pane) grows and its content is \(host.content.frame) in a clip of \(host.clipView.bounds)")
            #expect(host.clipView.layer?.masksToBounds == true, "\(pane) grows and the clip inside it does not cut")
        }
        #expect(grown > 0, "SETUP: the act makes no pane larger")
    }

    /// With the motion off no content is held: a split shows in one frame, and the content of the pane that gets
    /// smaller has its final size in that frame, as before the motion.
    @Test(arguments: ["Reduce Motion", "pane animations off"])
    func withTheMotionOffNoContentIsHeld(off: String) throws {
        // The setting is the app's own (`ui.paneAnimations`). This function has no suspension point, so no other test
        // on the main actor runs between the change and its restore.
        let setting = DesignSettings.shared.paneAnimations
        if off != "Reduce Motion" { DesignSettings.shared.paneAnimations = false }
        defer { DesignSettings.shared.paneAnimations = setting }
        let begun = try Self.begin(Motion.split, off: off)
        defer { begun.harness.window.closeAfterTest() }
        let context = begun.harness.root.context
        try #require(context.reduceMotion || !context.animatesPaneLayout, "SETUP: the pane animations are on")
        let host = try #require(Motion.hosts(of: begun.screen)[Commit.left], "the split's old pane does not show")
        #expect(!Motion.inFlight(begun.screen), "a pane has a move on its layer with the motion off")
        #expect(begun.took(Commit.left) == 1, "with the motion off the content of the pane that gets smaller took \(begun.took(Commit.left)) sizes in the frame that shows the split")
        #expect(host.content.frame == host.clipView.bounds, "with the motion off the content is \(host.content.frame) in a clip of \(host.clipView.bounds)")
        #expect(host.clipView.layer?.masksToBounds == true, "with the motion off the clip inside the pane does not cut")
    }
}
