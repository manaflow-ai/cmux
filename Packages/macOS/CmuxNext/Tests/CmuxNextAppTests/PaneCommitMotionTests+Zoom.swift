import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, a zoom (Cmd-Shift-Enter): the dim comes with the pane's move, not before it.
///
/// The zoom shows as any change does: its pane hears its size in the key's turn, and the first display frame after
/// it has the pane at its screen's size as its model. In that frame the pane starts its move from its place in the
/// layout before, the panes that it covers stay where they are under it, and the dim starts its fade over them. The
/// frame that ends the motion hides the covered panes and takes the dim away.
///
/// These rows hold, for that order, what `PaneZoomDimTests` held when a dim came before the zoom showed: a
/// second key, a screen switch, a change of the screen's size, panes that stop animating, a split and a close of
/// the zooming pane, each in the zoom's motion, and how many sizes the pane that zooms hears.
extension PaneCommitMotionTests {
    typealias Dim = PaneZoomDimTests

    /// A zoom on one pane of the 2 by 2 grid (p4, unless a row names another), with the key's turn done and `frames`
    /// display frames stepped.
    struct Zooming {
        let harness: Commit.Harness
        let screen: ScreenContentView
        /// The grid and the zoom at rest at the screen's size before the key.
        let grid: Commit.Rest
        let zoomed: Commit.Rest
        /// Where the grid's panes showed before the key, and p4's host layer's frame then.
        let places: Dim.Places
        let was: CGRect
    }

    /// `others`: more screens of the window, not shown. `pane`: the pane that zooms. `surfaces`: each pane's content
    /// is a producer that a change waits for (`Commit.Surface`); the zoom's own surfaces report in the key's turn, so
    /// the zoom shows in the first frame.
    static func zooming(frames: Int, others: [LayoutScreen] = [], pane: PaneID = "p4", surfaces: Bool = false) throws -> Zooming {
        let harness = Commit.Harness(Zoom.screens() + others, focused: pane, holds: false, surfaces: surfaces)
        let all = ["p1", "p2", "p3", "p4"] as [PaneID]
        var begun = false
        defer { if !begun { harness.window.closeAfterTest() } }
        movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.root.screenViews["s"], "SETUP: the shown screen has no view")
        let style = harness.root.context.style
        let grid = Commit.Rest(harness.model.screens, in: screen, style: style)
        try #require(grid.isShown(by: Commit.shown(screen)) && Dim.dim(harness) == nil, "SETUP: the grid does not rest with no dim")
        let places = try Dim.places(clear: pane, over: all.filter { $0 != pane }, in: harness)
        let was = try #require(harness.root.context.hosts[pane]?.layer?.frame)
        harness.model.apply(screens: Zoom.screens(zoomedOn: pane) + others)
        let zoomed = Commit.Rest(harness.model.screens, in: screen, style: style)
        harness.root.syncWithModel()
        for each in all { harness.provider.surface(each)?.report() }
        for _ in 0..<frames { _ = harness.root.advanceFrame(dt) }
        begun = true
        return Zooming(harness: harness, screen: screen, grid: grid, zoomed: zoomed, places: places, was: was)
    }

    /// Whether `screen` shows the zoomed pane at its screen's size and has no move in flight and no dim: the zoom at rest.
    static func restsZoomed(_ zoom: Zooming, at rest: Commit.Rest? = nil) -> Bool {
        (rest ?? zoom.zoomed).isShown(by: Commit.shown(zoom.screen)) && !inFlight(zoom.screen) && Dim.dim(zoom.harness) == nil
    }

    /// The zoom key's turn changes nothing on the screen. The first frame after it has the pane at its screen's size,
    /// with a move from its place in the grid; the panes it covers show at their places; and the dim comes over them
    /// on a fade from nothing, in the pane veil's time. The dim never covers the pane that zooms: at the start, the
    /// middle and the end of the move its parts leave the pane's content clear. The frame that ends the motion shows
    /// the zoomed pane alone with no dim, in the zoom's time.
    @Test func aZoomMovesItsPaneWhileTheDimComesOverTheOthers() throws {
        let zoom = try Self.zooming(frames: 0)
        defer { zoom.harness.window.closeAfterTest() }
        let harness = zoom.harness, screen = zoom.screen
        let fade = try Dim.fade()
        #expect(zoom.grid.isShown(by: Commit.shown(screen)), "the zoom's own turn changed what the screen shows")

        let asks = harness.root.advanceFrame(Self.dt)
        let hosts = Self.hosts(of: screen)
        let host = try #require(hosts["p4"], "the pane that zooms does not show"), layer = try #require(host.layer)
        let whole = try #require(zoom.zoomed.panes["p4"])
        #expect(Commit.near(host.frame, whole), "the first frame after the zoom key does not have the pane at its screen's size: \(host.frame)")
        let move = Self.move(of: layer)
        #expect(move.moves && Commit.near(move.start, zoom.was), "the pane that zooms has no move from its place in the grid: \(move.start), \(zoom.was)")
        for pane in ["p1", "p2", "p3"] as [PaneID] {
            let rect = try #require(zoom.grid.panes[pane])
            #expect(hosts[pane].map { Commit.near($0.frame, rect) } ?? false, "\(pane) does not show at its place under the pane that zooms")
        }
        #expect(asks, "the frame that begins the zoom's move asks for no frame")

        let dim = try #require(Dim.dim(harness), "the frame that begins the zoom's move shows no dim over the other panes")
        #expect(dim.layer.opacity > 0.05 && dim.layer.opacity < 0.9, "the dim's strength is \(dim.layer.opacity)")
        let coming = try #require(dim.layer.animation(forKey: "opacity") as? CABasicAnimation, "the dim comes with no fade on its layer")
        #expect((coming.fromValue as? Float) == 0, "the dim's fade is not from nothing: from \(String(describing: coming.fromValue))")
        #expect(coming.duration == fade, "the dim's fade on its layer is over \(coming.duration) s, not the pane veil's \(fade) s")
        // The dim's parts in the layout root's coordinates, as `PaneZoomDimTests.misses` reads them.
        let parts = (dim.layer.sublayers ?? []).map { Self.move(of: $0) }
        let hole = (from: zoom.places.clear.hole, to: harness.root.convert(host.contentRect, from: host))
        for part in [0, 0.5, 1] as [CGFloat] {
            let clear = Move(start: hole.from, end: hole.to).rect(at: part).insetBy(dx: 1, dy: 1)
            for piece in parts {
                let cut = piece.rect(at: part).offsetBy(dx: dim.view.frame.minX, dy: dim.view.frame.minY).intersection(clear)
                #expect(cut.isNull || cut.width < 0.5 || cut.height < 0.5, "at \(part) of the move the dim covers the pane that zooms: \(cut)")
            }
        }
        let starts = parts.map { $0.rect(at: 0).offsetBy(dx: dim.view.frame.minX, dy: dim.view.frame.minY) }
        for other in zoom.places.covered {
            #expect(starts.contains(where: { $0.contains(other.middle) }), "the dim does not cover \(other.pane) when it comes")
        }

        let (ticks, _) = Self.toTheEnd(harness, screen)
        #expect(Double(ticks) * Self.dt <= Self.zoom.time + 2 * Self.dt,
                "the zoom's motion ended \(Double(ticks) * Self.dt) s after the frame that began it; a zoom's time is \(Self.zoom.time) s")
        #expect(Self.restsZoomed(zoom), "after the motion's end the zoomed pane does not show alone with no dim: \(Commit.shown(screen).panes)")
        #expect(harness.provider.released.isEmpty, "the zoom released a pane: \(harness.provider.released)")
    }

    /// A second Cmd-Shift-Enter in the zoom's motion: the next frame shows every pane at its place in the grid, and no
    /// pane has a move on its layer (an unzoom of a pane that gives no last frame shows in one frame). Each frame after it shows the grid; a dim that the
    /// unzoom brings goes, and the frames stop.
    @Test func aSecondKeyInAZoomsMotionShowsEveryPaneAtItsPlace() throws {
        let zoom = try Self.zooming(frames: 3)
        defer { zoom.harness.window.closeAfterTest() }
        let harness = zoom.harness, screen = zoom.screen
        try #require(Self.inFlight(screen), "the pane that zooms does not move three frames after the key")
        harness.model.apply(screens: Zoom.screens())
        harness.root.syncWithModel()
        var asks = harness.root.advanceFrame(Self.dt)
        #expect(zoom.grid.isShown(by: Commit.shown(screen)), "the first frame after the second key does not show the grid: \(Commit.shown(screen).panes)")
        #expect(!Self.inFlight(screen), "a pane has a move on its layer in the frame that shows the unzoom")
        for tick in 2...Commit.frames {
            asks = harness.root.advanceFrame(Self.dt)
            #expect(zoom.grid.isShown(by: Commit.shown(screen)), "tick \(tick) shows another layout after the zoom was taken back")
        }
        #expect(!asks && Dim.dim(harness) == nil, "\(Commit.frames) frames after the second key frames run on, or a dim shows")
        #expect(harness.provider.released.isEmpty, "a pane was released: \(harness.provider.released)")
    }

    /// The turn of a second Cmd-Shift-Enter in the zoom's motion changes nothing that shows: the pane that zooms still
    /// has its move, the dim still shows, and no ring of a pane that the zoom covers shows over the pane that moves.
    /// The frame that shows the unzoom shows the rings, and the same dim goes: it is not taken away and put back.
    @Test func theTurnOfASecondKeyInAZoomsMotionKeepsTheDimAndShowsNoCoveredPanesRing() throws {
        let zoom = try Self.zooming(frames: 3)
        defer { zoom.harness.window.closeAfterTest() }
        let harness = zoom.harness, screen = zoom.screen
        let covered = ["p1", "p2", "p3"] as [PaneID]
        try #require(Self.inFlight(screen), "the pane that zooms does not move three frames after the key")
        let dim = try #require(Dim.dim(harness), "SETUP: no dim shows three frames into the zoom's move")
        harness.model.apply(screens: Zoom.screens())
        harness.root.syncWithModel()
        #expect(Dim.dim(harness)?.view === dim.view, "the second key's turn took the dim away before its change shows")
        #expect(Self.inFlight(screen), "the second key's turn ended the pane's move before its change shows")
        for pane in covered {
            let host = try #require(harness.root.context.hosts[pane], "\(pane) has no host after the second key")
            #expect(!host.isHidden && host.chrome.isHidden, "\(pane)'s ring shows in the second key's turn, over the pane that still moves")
        }
        _ = harness.root.advanceFrame(Self.dt)
        for pane in covered {
            #expect(harness.root.context.hosts[pane]?.chrome.isHidden == false, "\(pane)'s ring does not show in the frame that shows the unzoom")
        }
        let going = try #require(Dim.dim(harness), "the frame that shows the unzoom shows no dim")
        #expect(going.view === dim.view, "the unzoom's dim is another view than the zoom's: the dim was taken away and put back")
        let fade = try #require(going.layer.animation(forKey: "opacity") as? CABasicAnimation, "the unzoom's dim has no fade on its layer")
        #expect((fade.toValue as? Float) == 0, "the unzoom's dim does not go: its fade ends at \(String(describing: fade.toValue))")
    }

    /// A second Cmd-Shift-Enter in the LAST tick of the zoom's motion, with an unzoom that waits for its pane's
    /// surface: the tick in which the zoom's time is spent comes before the frame that shows the unzoom. The motion
    /// does not end under the change that waits. In the key's turn and in each tick of the wait the zoomed pane still
    /// has its screen's size, the dim still shows, and each pane that the zoom covers is under the zoomed pane with
    /// no ring. The FIRST pane of the grid zooms: the panes that it covers are after it in the screen's order, so each
    /// would show over it at full light. The frame that shows the unzoom shows the grid and the rings, and the same
    /// dim goes.
    @Test func aSecondKeyInTheLastTickOfAZoomsMotionKeepsTheZoomUntilItsChangeShows() throws {
        // How many frames the zoom's motion takes after the frame that begins it: one run of it to its end.
        let whole = try Self.zooming(frames: 1, pane: "p1", surfaces: true)
        defer { whole.harness.window.closeAfterTest() }
        let ticks = Self.toTheEnd(whole.harness, whole.screen).ticks
        try #require(ticks > 3 && ticks < Commit.frames, "SETUP: the zoom's motion took \(ticks) frames")

        // One frame less: the next frame is the tick in which the zoom's time is spent.
        let zoom = try Self.zooming(frames: ticks, pane: "p1", surfaces: true)
        defer { zoom.harness.window.closeAfterTest() }
        let harness = zoom.harness, screen = zoom.screen
        let covered = ["p2", "p3", "p4"] as [PaneID]
        try #require(Self.inFlight(screen), "SETUP: the zoom's motion ended a tick before its time")
        let dim = try #require(Dim.dim(harness), "SETUP: no dim shows in the zoom's last tick")
        let surface = try #require(harness.provider.surface("p1"), "SETUP: the zoomed pane has no surface")
        let asked = surface.asks.count

        harness.model.apply(screens: Zoom.screens())
        harness.root.syncWithModel()
        try #require(surface.asks.count == asked + 1, "SETUP: the unzoom asks the zoomed pane's surface for no size: it does not wait")
        func staysZoomed(_ when: String) throws {
            #expect(Self.places(zoom.zoomed, on: screen), "\(when): the zoomed pane does not have its screen's size: \(Commit.shown(screen).panes)")
            #expect(Dim.dim(harness)?.view === dim.view, "\(when): the zoom's dim is gone before the unzoom shows")
            for pane in covered {
                let host = try #require(harness.root.context.hosts[pane], "\(pane) has no host after the second key")
                #expect(!host.isHidden && host.chrome.isHidden, "\(when): \(pane)'s ring shows over the zoomed pane")
                #expect((host.layer?.zPosition ?? 0) < 0, "\(when): \(pane) is not under the zoomed pane: it shows over it at full light")
            }
        }
        try staysZoomed("the second key's turn")
        for tick in 1...2 {
            #expect(harness.root.advanceFrame(Self.dt), "tick \(tick) of the unzoom's wait asks for no frame")
            try staysZoomed("tick \(tick) of the unzoom's wait")
        }

        surface.report()
        _ = harness.root.advanceFrame(Self.dt)
        #expect(zoom.grid.isShown(by: Commit.shown(screen)), "the first frame after the surface's report does not show the grid: \(Commit.shown(screen).panes)")
        for pane in covered {
            let host = harness.root.context.hosts[pane]
            #expect(host?.chrome.isHidden == false && (host?.layer?.zPosition ?? -1) >= 0,
                    "\(pane) does not show with its ring in the frame that shows the unzoom")
        }
        let going = try #require(Dim.dim(harness), "the frame that shows the unzoom shows no dim")
        #expect(going.view === dim.view, "the unzoom's dim is another view than the zoom's: the dim was taken away and put back")
        let fade = try #require(going.layer.animation(forKey: "opacity") as? CABasicAnimation, "the unzoom's dim has no fade on its layer")
        #expect((fade.toValue as? Float) == 0, "the unzoom's dim does not go: its fade ends at \(String(describing: fade.toValue))")
    }

    /// A screen switch in the zoom's motion ends the motion and the dim: the screen that the switch shows has no dim
    /// over it, and the screen that hid shows its zoom at rest when it shows again.
    @Test func aScreenSwitchInAZoomsMotionEndsIt() throws {
        let other = LayoutScreen(id: "t", name: "t", layout: .splits(.leaf("q1")))
        let zoom = try Self.zooming(frames: 3, others: [other])
        defer { zoom.harness.window.closeAfterTest() }
        let harness = zoom.harness
        try #require(Self.inFlight(zoom.screen), "the pane that zooms does not move three frames after the key")
        harness.model.selectScreen("t")
        harness.root.syncWithModel()
        #expect(Dim.dim(harness) == nil, "the dim stays over the screen the switch shows")
        for tick in 1...Commit.frames {
            _ = harness.root.advanceFrame(Self.dt)
            #expect(Dim.dim(harness) == nil, "tick \(tick): a dim shows over the other screen")
        }
        #expect(!Self.inFlight(zoom.screen), "a pane of the hidden screen still has a move on its layer")
        harness.model.selectScreen("s")
        harness.root.syncWithModel()
        #expect(Self.restsZoomed(zoom), "back on its screen the zoomed pane does not show alone, at rest, with no dim: \(Commit.shown(zoom.screen).panes)")
    }

    /// Panes stop animating in the zoom's motion (Reduce Motion turned on): the next frame ends the motion and shows
    /// the zoomed pane alone with no dim, and no frame is asked for after it.
    @Test func whenPanesStopAnimatingInAZoomsMotionTheZoomShowsWhole() throws {
        let zoom = try Self.zooming(frames: 3)
        defer { zoom.harness.window.closeAfterTest() }
        try #require(Self.inFlight(zoom.screen), "the pane that zooms does not move three frames after the key")
        zoom.harness.root.context.reduceMotionOverride = true
        _ = zoom.harness.root.advanceFrame(Self.dt)
        #expect(Self.restsZoomed(zoom), "the frame after panes stopped animating does not show the zoomed pane alone, at rest: \(Commit.shown(zoom.screen).panes)")
        #expect(Commit.shown(zoom.screen).misfits.isEmpty, "the zoomed pane's content is not at the rect its pane gives it")
        #expect(!zoom.harness.root.advanceFrame(Self.dt) || !zoom.harness.root.advanceFrame(Self.dt), "frames run on after the zoom showed whole")
    }

    /// A change of the screen's size in the zoom's motion (the window's edge moves) ends the motion and the dim: at
    /// most two frames later the zoomed pane shows alone at the screen's new size.
    @Test func aChangeOfTheScreensSizeInAZoomsMotionEndsIt() throws {
        let zoom = try Self.zooming(frames: 3)
        defer { zoom.harness.window.closeAfterTest() }
        let harness = zoom.harness, screen = zoom.screen
        try #require(Self.inFlight(screen), "the pane that zooms does not move three frames after the key")
        harness.window.setContentSize(NSSize(width: 1400, height: 900))
        harness.root.layoutSubtreeIfNeeded()
        try #require(screen.bounds.size == NSSize(width: 1400, height: 900), "SETUP: the screen did not take the window's new size: \(screen.bounds.size)")
        let resized = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)
        for _ in 0..<2 { _ = harness.root.advanceFrame(Self.dt) }
        #expect(Self.restsZoomed(zoom, at: resized), "two frames after the size change the zoomed pane does not show alone at the new size: \(Commit.shown(screen).panes)")
        #expect(Commit.shown(screen).misfits.isEmpty, "the zoomed pane's content is not at the rect its pane gives it")
    }

    /// The pane that zooms hears ONE size in one zoom, in the key's turn, as the pane of any change does: the zoom
    /// waits for its producer's report, shows in the frame after it, and no frame of the motion tells a size.
    @Test func thePaneThatZoomsHearsOneSizeInTheKeysTurn() throws {
        let harness = Commit.Harness(Zoom.screens(), focused: "p4", holds: false, surfaces: true)
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let surface = try #require(harness.provider.surface("p4"), "SETUP: the pane that zooms has no producer")
        let asked = surface.asks.count
        harness.model.apply(screens: Zoom.screens(zoomedOn: "p4"))
        let zoomed = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)
        harness.root.syncWithModel()
        #expect(surface.asks.count == asked + 1, "the zoom's own turn told the pane that zooms \(surface.asks.count - asked) sizes, not 1")
        _ = harness.root.advanceFrame(Self.dt)
        #expect(!Self.places(zoomed, on: screen), "the zoom showed before its producer reported")
        surface.report()
        _ = harness.root.advanceFrame(Self.dt)
        #expect(Self.places(zoomed, on: screen), "the frame after the producer's report does not have the pane at its screen's size")
        try #require(Self.inFlight(screen), "the pane that zooms has no move in the frame that shows the zoom")
        _ = Self.toTheEnd(harness, screen)
        #expect(surface.asks.count == asked + 1, "the pane that zooms heard \(surface.asks.count - asked) sizes in one zoom, not 1")
        #expect(zoomed.isShown(by: Commit.shown(screen)) && Dim.dim(harness) == nil, "after the motion's end the zoom does not show alone with no dim")
        #expect(screen.lateSurfaceCommits == 0, "the zoom counts \(screen.lateSurfaceCommits) late panes")
    }

    /// A split in the zoom's motion is a change of its own: it waits for its producers as any change does, and the
    /// motion's frames use up none of that wait. The frame after the report has the split's layout as its model.
    @Test func aSplitInAZoomsMotionWaitsForItsProducers() throws {
        let harness = Commit.Harness(Commit.pair, focused: Commit.left, holds: false, surfaces: true)
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let left = try #require(harness.provider.surface(Commit.left), "SETUP: the pane that zooms has no producer")
        harness.model.apply(screens: Commit.pairZoomed)
        harness.root.syncWithModel()
        left.report()
        for _ in 0..<5 { _ = harness.root.advanceFrame(Self.dt) }
        try #require(Self.inFlight(screen), "the pane that zooms does not move five frames after the key")

        // The pane that zooms splits: the zoom is gone, and the split resizes that pane.
        harness.model.apply(screens: Commit.pairSplit(.horizontal))
        let split = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)
        harness.root.syncWithModel()
        #expect(harness.root.advanceFrame(Self.dt), "the split asks for no frame while its producer has not reported")
        #expect(!Self.places(split, on: screen), "the split showed before its producer reported: the motion's frames used up its wait")
        left.report()
        _ = harness.root.advanceFrame(Self.dt)
        #expect(Self.places(split, on: screen), "the frame after the producer's report does not have the split's layout: \(Self.hosts(of: screen).mapValues(\.frame))")
        #expect(screen.lateSurfaceCommits == 0, "the split counts \(screen.lateSurfaceCommits) late panes")
    }

    /// The pane that zooms closes in its motion (the close comes with the daemon's tree). The close is a change of its
    /// own: each frame from the next one has the panes that stay at their places, with their content at its rect, and
    /// when the frames stop the screen shows those panes alone with no dim.
    @Test func aCloseOfThePaneThatZoomsInItsMotionShowsThePanesThatStay() throws {
        let zoom = try Self.zooming(frames: 3)
        defer { zoom.harness.window.closeAfterTest() }
        let harness = zoom.harness, screen = zoom.screen
        try #require(Self.inFlight(screen), "the pane that zooms does not move three frames after the key")
        // The grid less p4: p3 takes the whole right half.
        let stays: SplitNode = .split("r", axis: .horizontal, ratio: 0.5,
                                      a: .split("a", axis: .vertical, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")), b: .leaf("p3"))
        harness.model.apply(screens: Commit.screen(stays))
        let closed = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)
        harness.root.syncWithModel()
        var asks = true
        for tick in 1...Commit.frames {
            asks = harness.root.advanceFrame(Self.dt)
            #expect(Self.places(closed, on: screen),
                    "tick \(tick) does not have the panes that stay at their places: \(Self.hosts(of: screen).mapValues(\.frame))")
            let misfits = Commit.shown(screen).misfits.filter { closed.panes[$0.key] != nil }
            #expect(misfits.isEmpty, "tick \(tick): a pane's content is not at the rect its pane gives it: \(misfits)")
        }
        #expect(closed.isShown(by: Commit.shown(screen)) && !Self.inFlight(screen), "\(Commit.frames) frames after the close the screen does not show the panes that stay alone, at rest")
        #expect(!asks && Dim.dim(harness) == nil, "\(Commit.frames) frames after the close frames run on, or a dim shows")
    }

    /// A zoom key while an unzoom's dim still goes: the zoom shows in its first frame, its pane moves, and the dim
    /// stays over the other panes and comes again. The frame that ends the motion shows the zoomed pane alone.
    @Test func aZoomWhileAnUnzoomsDimGoesMovesItsPaneUnderTheDim() throws {
        let zoom = try Self.zooming(frames: 0)
        defer { zoom.harness.window.closeAfterTest() }
        let harness = zoom.harness, screen = zoom.screen
        Commit.rest(harness)
        try #require(zoom.zoomed.isShown(by: Commit.shown(screen)) && Dim.dim(harness) == nil, "SETUP: the zoom did not come to rest with no dim")
        harness.model.apply(screens: Zoom.screens())
        harness.root.syncWithModel()
        for _ in 0..<2 { _ = harness.root.advanceFrame(Self.dt) }
        try #require(Dim.dim(harness) != nil && zoom.grid.isShown(by: Commit.shown(screen)), "SETUP: two frames after the unzoom its dim does not show over the grid")

        harness.model.apply(screens: Zoom.screens(zoomedOn: "p4"))
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        #expect(Self.places(zoom.zoomed, on: screen), "the first frame after the zoom key does not have the pane at its screen's size")
        try #require(Self.inFlight(screen), "the pane that zooms has no move in the frame that shows the zoom")
        let dim = try #require(Dim.dim(harness), "the frame that begins the zoom's move shows no dim over the other panes")
        #expect(dim.layer.opacity > 0.05, "the dim does not come: its strength goes to \(dim.layer.opacity)")
        _ = Self.toTheEnd(harness, screen)
        #expect(Self.restsZoomed(zoom), "after the motion's end the zoomed pane does not show alone with no dim: \(Commit.shown(screen).panes)")
        #expect(harness.provider.released.isEmpty, "a pane was released: \(harness.provider.released)")
    }
}
