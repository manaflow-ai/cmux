import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, the panes that an act takes out of the layout: a pane that a zoom covers and a pane that a
/// close took out show under the panes of the new layout until the motion's end, and they cut nothing from them.
///
/// A pane's content is cut by a mask on its host's layer: the strip's range beside a docked column, and the rects of
/// the panes in front of it (`ScreenContentView.clipToStrip`, `panesAbove()`). A pane that left the layout is in front
/// of no pane of the layout. So the pane that takes its room shows whole over it: in the frame that shows the act, in
/// each frame of the move and after the move's end. A zoom beside a docked column shows its pane over the column's
/// place too.
///
/// A screen's first pane hosts have no fixed order among them, so a row reads the order and takes the lowest host.
extension PaneCommitMotionTests {
    /// A zoom beside a column at the right edge: how the column shares the screen, and whether the zoomed pane's
    /// content moves (a pane with a page's stand-in in its content area zooms in one frame).
    struct Docked: CustomTestStringConvertible, Sendable {
        let mode: DockMode
        let moves: Bool
        var testDescription: String { "\(mode.rawValue) column, the pane \(moves ? "moves" : "shows in one frame")" }
    }

    nonisolated static let docks = [
        Docked(mode: .docked, moves: true), Docked(mode: .overlay, moves: true),
        Docked(mode: .docked, moves: false), Docked(mode: .overlay, moves: false),
    ]

    /// Two strip columns and a column at the right edge in `mode`; with `pane`, that pane alone on its screen (a zoom).
    static func dockStrip(_ mode: DockMode, zoomedOn pane: PaneID? = nil) -> [LayoutScreen] {
        let columns = ScreenLayout.columns([
            LayoutColumn(id: "c1", width: 0.6, root: .leaf("p1")),
            LayoutColumn(id: "c2", width: 0.6, root: .leaf("p2")),
            LayoutColumn(id: "dock", width: 0.3, root: .leaf("chat"), dock: DockColumn(edge: .right, mode: mode)),
        ])
        let layout = pane.map { ScreenLayout.splits(.leaf($0)) } ?? columns
        return [LayoutScreen(id: "s", name: "s", layout: layout, zoomed: pane != nil)]
    }

    // MARK: What a mask cuts

    /// What the mask on `host` cuts from it. Nil: no mask, or a mask of the host's whole bounds with no cutout.
    static func cut(of host: PaneHostView) -> String? {
        guard let mask = host.layer?.mask else { return nil }
        let holes = (mask as? StripClipMaskLayer)?.cutouts ?? []
        if holes.isEmpty, Commit.near(mask.frame, host.bounds) { return nil }
        return "a mask of \(mask.frame) with \(holes.count) cutouts on a host of \(host.bounds.size)"
    }

    static func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }

    /// The area of `place` (the screen's coordinates) in which `host` shows: its frame, less what its mask cuts.
    static func area(of place: CGRect, shownBy host: PaneHostView) -> CGFloat {
        let origin = host.frame.origin
        guard let mask = host.layer?.mask else { return area(host.frame.intersection(place)) }
        let inside = mask.frame.offsetBy(dx: origin.x, dy: origin.y).intersection(host.frame).intersection(place)
        let holes = (mask as? StripClipMaskLayer)?.cutouts ?? []
        return area(inside) - holes.reduce(CGFloat(0)) { $0 + area($1.offsetBy(dx: origin.x, dy: origin.y).intersection(inside)) }
    }

    /// What a mask cut from one pane host through an act: in the frame that shows the act, in each later frame in
    /// which a pane still moved, and in the frame that ended the motion and the 2 frames after it.
    struct Cuts {
        var first: String?
        var moving: [String] = []
        var after: [String] = []
        /// The display frames that were stepped while a pane moved.
        var frames = 0
    }

    /// Steps the motion of `screen` to its end and 2 frames more. The frame that shows the act is stepped already.
    static func cuts(of host: PaneHostView, _ harness: Commit.Harness, _ screen: ScreenContentView) -> Cuts {
        var found = Cuts(first: cut(of: host))
        while inFlight(screen), found.frames < Commit.frames {
            _ = harness.root.advanceFrame(dt)
            found.frames += 1
            if inFlight(screen), let mask = cut(of: host) { found.moving.append("frame \(found.frames + 1): \(mask)") }
        }
        for extra in 0...2 {
            if extra > 0 { _ = harness.root.advanceFrame(dt) }
            if let mask = cut(of: host) { found.after.append("\(extra) frames after the end: \(mask)") }
        }
        return found
    }

    /// Puts a view of another kind over the content area of `pane` (a page's stand-in): the pane does not ride, so an
    /// act that changes its rect shows in one frame.
    static func putAPage(over pane: PaneID, _ harness: Commit.Harness) -> Bool {
        guard let content = harness.provider.contents[pane] else { return false }
        let area = PaneContentAreaView(frame: content.bounds)
        area.autoresizingMask = [.width, .height]
        let page = NSView(frame: area.bounds)
        page.autoresizingMask = [.width, .height]
        area.addSubview(page)
        content.addSubview(area)
        return true
    }

    // MARK: A zoom beside a docked column

    /// A zoom takes the docked column out of the screen, and the zoomed pane has the column's place too. The zoomed
    /// pane shows whole from the frame that shows the zoom: its frame and its content hold the column's place, no
    /// mask cuts it, and in the zoomed state it is the pane that shows in the column's place.
    @Test(arguments: docks)
    func aZoomBesideADockShowsItsPaneWholeOverTheDocksPlace(_ dock: Docked) throws {
        let harness = Commit.Harness(Self.dockStrip(dock.mode), focused: "p1", holds: false)
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let rest = Self.hosts(of: screen)
        let place = try #require(rest["chat"]?.frame, "SETUP: the docked column's pane does not show at rest")
        let all = Self.area(place)
        try #require(rest.count == 3 && all > 1, "SETUP: the screen does not rest with its 3 panes: \(rest.mapValues(\.frame))")
        if !dock.moves { try #require(Self.putAPage(over: "p1", harness), "SETUP: the pane that zooms has no content") }

        harness.model.apply(screens: Self.dockStrip(dock.mode, zoomedOn: "p1"))
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        let host = try #require(harness.root.context.hosts["p1"], "SETUP: the zoomed pane has no host")
        #expect(Self.inFlight(screen) == dock.moves, "SETUP: the zoomed pane \(dock.moves ? "has no move" : "has a move") on its layer")

        let cuts = Self.cuts(of: host, harness, screen)
        #expect(cuts.first == nil, "the frame that shows the zoom cuts the zoomed pane: \(cuts.first ?? "")")
        #expect(cuts.moving.isEmpty, "\(cuts.moving.count) of the \(cuts.frames) frames of the move cut the zoomed pane: \(cuts.moving.first ?? "")")
        #expect(cuts.after.isEmpty, "after the motion's end the zoomed pane is cut: \(cuts.after)")

        // The zoomed state.
        let shown = Self.hosts(of: screen)
        #expect(Set(shown.keys) == ["p1"], "the zoomed state shows these panes: \(shown.keys.sorted())")
        let framed = Self.area(host.frame.intersection(place))
        #expect(framed >= 0.9 * all, "the zoomed pane's frame \(host.frame) holds \(framed) pt2 of the \(all) pt2 of the column's place \(place)")
        let content = screen.convert(host.content.bounds, from: host.content)
        let filled = Self.area(content.intersection(place))
        #expect(Commit.shown(screen).misfits["p1"] == nil && filled >= 0.8 * all,
                "the zoomed pane's content \(content) holds \(filled) pt2 of the \(all) pt2 of the column's place \(place), or is not at its pane's rect")
        let seen = Self.area(of: place, shownBy: host)
        #expect(seen >= 0.9 * all, "in the zoomed state the zoomed pane shows in \(seen) pt2 of the \(all) pt2 of the column's place \(place): the rest shows no pane")
    }

    /// An unzoom brings the docked column back, and each pane is cut as it was before the zoom: in the frame that
    /// shows the unzoom, and at rest after it.
    @Test(arguments: DockMode.allCases)
    func anUnzoomBesideADockCutsEachPaneAsBeforeTheZoom(_ mode: DockMode) throws {
        let harness = Commit.Harness(Self.dockStrip(mode), focused: "p1", holds: false)
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        func masks() -> [PaneID: String] { Self.hosts(of: screen).mapValues { Self.cut(of: $0) ?? "whole" } }
        let before = masks()
        try #require(before.count == 3, "SETUP: the screen does not rest with its 3 panes: \(before)")
        harness.model.apply(screens: Self.dockStrip(mode, zoomedOn: "p1"))
        harness.root.syncWithModel()
        Commit.rest(harness)
        try #require(Set(Self.hosts(of: screen).keys) == ["p1"], "SETUP: the zoom did not come to rest with one pane")

        harness.model.apply(screens: Self.dockStrip(mode))
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        let first = masks()
        #expect(first == before, "the frame that shows the unzoom cuts the panes as \(first); before the zoom: \(before)")
        Commit.rest(harness)
        let after = masks()
        #expect(after == before, "at rest after the unzoom the panes are cut as \(after); before the zoom: \(before)")
    }

    // MARK: A pane under the pane that leaves

    /// The pair at rest with the move on, then its lowest pane host's pane alone on the screen: by a zoom, or by a
    /// close of the pane above it. The first display frame after the act is stepped.
    struct Alone {
        let harness: Commit.Harness
        let screen: ScreenContentView
        /// The host of the pane that stays, and where the other pane showed at rest.
        let host: PaneHostView
        let place: CGRect
    }

    static func alone(zoomed: Bool) throws -> Alone {
        let harness = Commit.Harness(Commit.pair, focused: Commit.left, holds: false)
        var begun = false
        defer { if !begun { harness.window.closeAfterTest() } }
        movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let order = screen.subviews.compactMap { $0 as? PaneHostView }.filter { !$0.isHidden }
        try #require(order.count == 2, "SETUP: the pair shows \(order.count) pane hosts at rest")
        let host = order[0], place = order[1].frame
        harness.model.focus(host.pane, notify: false)
        Commit.rest(harness)
        try #require(cut(of: host) == nil, "SETUP: the lowest pane of the pair is cut at rest: \(cut(of: host) ?? "")")

        harness.model.apply(screens: Commit.screen(.leaf(host.pane), zoomed: zoomed))
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(dt)
        try #require(harness.root.context.hosts[host.pane] === host, "SETUP: the pane that stays has another host after the act")
        try #require(inFlight(screen), "SETUP: no pane moves: the act shows in one frame")
        begun = true
        return Alone(harness: harness, screen: screen, host: host, place: place)
    }

    /// A zoom of the pane that is under the other pane of a pair, and a close of the pane that is above the other: the
    /// pane that takes the screen shows whole, over the place of the pane that left, in the frame that shows the act,
    /// in each frame of the move and after its end.
    @Test(arguments: [true, false])
    func aPaneThatTakesTheRoomOfAPaneAboveItShowsWhole(zoomed: Bool) throws {
        let alone = try Self.alone(zoomed: zoomed)
        defer { alone.harness.window.closeAfterTest() }
        let act = zoomed ? "zoom" : "close"
        let cuts = Self.cuts(of: alone.host, alone.harness, alone.screen)
        #expect(cuts.first == nil, "the frame that shows the \(act) cuts the pane that takes the screen: \(cuts.first ?? "")")
        #expect(cuts.moving.isEmpty, "\(cuts.moving.count) of the \(cuts.frames) frames of the move cut the pane that takes the screen: \(cuts.moving.first ?? "")")
        #expect(cuts.after.isEmpty, "after the motion's end the pane that takes the screen is cut: \(cuts.after)")
        let all = Self.area(alone.place), seen = Self.area(of: alone.place, shownBy: alone.host)
        #expect(seen >= 0.9 * all, "after the \(act) the pane shows in \(seen) pt2 of the \(all) pt2 of the other pane's place \(alone.place)")
    }
}
