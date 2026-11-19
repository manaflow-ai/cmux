import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, the window's colour under a pane that moves.
///
/// A pane's tab row and the padding around its content have no ground: at rest the window's sheet shows there. In a
/// window whose sheet is one plain colour a pane that moves has that colour on its host's layer, under its content
/// and on its whole cell, from the frame that shows its act to the last frame of the motion. So a pane under it (a
/// pane that a close took out, a pane that a zoom covers, the panes that an unzoom's pane closes over) shows nowhere
/// in its rect, also not through its tab row. The colour is the window's own, and it adds no layer and no mask.
/// A window that shows what is behind it has no such colour.
extension PaneCommitMotionTests {
    /// The parts of a move at which a row reads a frame: the start, each quarter and the end.
    nonisolated static let quarters: [CGFloat] = [0, 0.25, 0.5, 0.75, 1]

    /// `color` in sRGB, each part from 0 to 255; nil: no colour.
    static func rgba(_ color: CGColor?) -> [Int]? {
        guard let color, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let parts = color.converted(to: space, intent: .defaultIntent, options: nil)?.components else { return nil }
        return parts.map { Int(($0 * 255).rounded()) }
    }

    /// The colour of the sheet of the window of `screen`, as the screen's appearance reads it.
    static func sheet(of screen: ScreenContentView) -> CGColor? {
        var color: CGColor?
        screen.effectiveAppearance.performAsCurrentDrawingAppearance { color = screen.window?.backgroundColor.cgColor }
        return color
    }

    /// A zoom and a close of a pair, in an opaque window. In the frame that shows the act, and in the last frame in
    /// which a pane moves, the pane that moves has the window's colour on its layer, with alpha 1. After the motion's
    /// end it has no colour: the pane shows the window's sheet where it has no ground, as before the act.
    @Test(arguments: [true, false])
    func aPaneThatMovesHasTheWindowsColourUnderItsContent(zoomed: Bool) throws {
        let alone = try Self.alone(zoomed: zoomed)
        defer { alone.harness.window.closeAfterTest() }
        let act = zoomed ? "zoom" : "close"
        let layer = try #require(alone.host.layer, "SETUP: the pane that moves has no layer")
        let sheet = Self.sheet(of: alone.screen)
        try #require(alone.harness.window.isOpaque && (sheet?.alpha ?? 0) >= 1, "SETUP: the test's window is not opaque with a colour of alpha 1")
        #expect(Self.rgba(layer.backgroundColor) == Self.rgba(sheet),
                "in the frame that shows the \(act) the pane that moves has \(String(describing: Self.rgba(layer.backgroundColor))) under its content; the window has \(String(describing: Self.rgba(sheet)))")
        var last = layer.backgroundColor, frames = 0
        while Self.inFlight(alone.screen), frames < Commit.frames {
            last = layer.backgroundColor
            _ = alone.harness.root.advanceFrame(Self.dt)
            frames += 1
        }
        #expect(Self.rgba(last) == Self.rgba(sheet),
                "in the last frame of the \(act)'s move the pane has \(String(describing: Self.rgba(last))) under its content; the window has \(String(describing: Self.rgba(sheet)))")
        #expect(layer.backgroundColor == nil, "after the motion's end the pane keeps the colour \(String(describing: Self.rgba(layer.backgroundColor))) on its layer")
    }

    /// The pair with its lowest pane alone after a close, then that pane split again in the close's move, with the
    /// frame that shows the split stepped. `colour`: the window gets this colour between the 2 acts.
    static func closeThenSplit(colour: NSColor? = nil) throws -> (alone: Alone, left: PaneHostView, came: PaneHostView) {
        let alone = try Self.alone(zoomed: false)
        var begun = false
        defer { if !begun { alone.harness.window.closeAfterTest() } }
        let left = try #require(alone.screen.subviews.compactMap { $0 as? PaneHostView }.first { $0 !== alone.host && !$0.isHidden },
                                "SETUP: the pane that left does not show in the close's move")
        if let colour { alone.harness.window.backgroundColor = colour }
        let halves = SplitNode.split(SplitID("again"), axis: .horizontal, ratio: 0.5, a: .leaf(alone.host.pane), b: .leaf(Commit.added))
        alone.harness.model.apply(screens: Commit.screen(halves))
        alone.harness.root.syncWithModel()
        _ = alone.harness.root.advanceFrame(Self.dt)
        let came = try #require(alone.harness.root.context.hosts[Commit.added], "SETUP: the pane that the split brought has no host")
        try #require(Self.acts(on: alone.screen).count == 2, "SETUP: the split in the close's move ended the move, or shows in one frame")
        begun = true
        return (alone, left, came)
    }

    /// A close, then a split of the pane that grows, in the close's move: 2 panes with one edge between them, each
    /// with the moves of its acts, where the pane that left was. The pass that shows the split hides the pane that
    /// left; a move that keeps it shows it nowhere under those 2 panes, and through none of them.
    @Test func afterACloseThenASplitThePaneThatLeftShowsNowhereUnderThePanesOverIt() throws {
        let scene = try Self.closeThenSplit()
        defer { scene.alone.harness.window.closeAfterTest() }
        let screen = scene.alone.screen, acts = Self.acts(on: screen)
        let kept = scene.left.isHidden ? [] : [scene.left]
        let margin = Self.margin(among: [scene.alone.host, scene.came])
        for (early, late) in [(0.5, 0), (0.75, 0.25), (0.9, 0.5), (1, 0.75), (1, 1)] as [(CGFloat, CGFloat)] {
            Self.expectKept(kept, on: screen, margin: margin, "with the close at \(early) and the split at \(late)") { $0 == acts[1] ? late : early }
        }
        #expect(Self.keepsInOrder(kept, on: screen), "the pane that left is not under each pane of the layout")
        #expect(scene.left.isHidden || scene.left.isLeaving, "the pane that left shows again as a pane of the layout")
    }

    /// The window's colour changes in a move (a theme change): the pass of the next act gives each pane that has the
    /// colour the window's new one, the panes of the act before too.
    @Test func afterTheWindowsColourChangesInAMoveTheNextActGivesEachPaneTheNewColour() throws {
        let new = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let scene = try Self.closeThenSplit(colour: new)
        defer { scene.alone.harness.window.closeAfterTest() }
        for host in [scene.alone.host, scene.came] {
            #expect(Self.rgba(host.layer?.backgroundColor) == Self.rgba(new.cgColor),
                    "the pane \(host.pane) has \(String(describing: Self.rgba(host.layer?.backgroundColor))) under its content; the window has \(String(describing: Self.rgba(new.cgColor)))")
        }
    }

    /// An unzoom: its pane closes to its place over the panes that come back, which show at their places from the
    /// frame that shows the unzoom. At the start, at each quarter and at the end of its move the screen shows none of
    /// them in its rect, also not through its tab row.
    @Test func anUnzoomsPaneShowsNoPaneThatComesBackUnderIt() throws {
        let unzoom = try Self.unzooming(frames: 1)
        defer { unzoom.zoom.harness.window.closeAfterTest() }
        let screen = unzoom.zoom.screen
        let move = try #require(unzoom.host.layer.map { Self.move(of: $0) }, "SETUP: the unzoom's pane has no layer")
        let others = Self.stack(on: screen).filter { $0 !== unzoom.host }
        try #require(move.moves && others.count == 3 && Self.stack(on: screen).last === unzoom.host,
                     "SETUP: the unzoom's pane does not move over the 3 panes that come back (\(others.count) show)")
        for part in Self.quarters {
            let over = move.rect(at: part)
            for other in others {
                let seen = Self.kept(other, on: screen, over: [unzoom.host], at: part)
                #expect(seen.area(in: over) < 1 && seen.through < 1,
                        "at \(part) of the unzoom's move the screen shows \(seen.area(in: over)) pt2 of \(other.pane) in the rect \(over) of the pane that closes over it, \(seen.through) pt2 through it")
            }
        }
    }

    /// Each mode of a column at the screen's edge, by its name.
    nonisolated static let dockModes: [String] = DockMode.allCases.map { $0.rawValue }

    /// A zoom of a strip pane beside a column at the right edge. The zoomed pane grows over the other strip pane and
    /// over the column's pane: at the start, at each quarter and at the end of its move the screen shows none of them in
    /// its rect, also not through its tab row.
    @Test(arguments: dockModes)
    func aZoomBesideAColumnShowsNoPaneUnderTheZoomedPane(_ mode: String) throws {
        let dock = try #require(DockMode(rawValue: mode), "SETUP: no dock mode \(mode)")
        let harness = Commit.Harness(Self.dockStrip(dock), focused: "p1", holds: false)
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        harness.model.apply(screens: Self.dockStrip(dock, zoomedOn: "p1"))
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        let screen = try #require(harness.screen)
        let host = try #require(harness.root.context.hosts["p1"], "SETUP: the pane that zooms has no host")
        let kept = screen.subviews.compactMap { $0 as? PaneHostView }.filter { $0.isLeaving && !$0.isHidden }
        let move = try #require(host.layer.map { Self.move(of: $0) }, "SETUP: the pane that zooms has no layer")
        try #require(move.moves && !kept.isEmpty, "SETUP: the zoomed pane does not move, or the move keeps no pane that it covers")
        for part in Self.quarters {
            let over = move.rect(at: part)
            for under in kept {
                let seen = Self.kept(under, on: screen, over: [host], at: part)
                #expect(seen.area(in: over) < 1 && seen.through < 1,
                        "at \(part) of the zoom's move the screen shows \(seen.area(in: over)) pt2 of \(under.pane) in the rect \(over) of the zoomed pane, \(seen.through) pt2 through it")
            }
        }
    }

    /// A hold of the close key: 10 closes, each in the move of the one before. A close adds no layer to a pane host
    /// and puts no mask on a pane's clip: the count is the count at rest after the fourth key and after the tenth.
    /// Each pane that moves has the window's colour on its own layer.
    @Test func aHoldOfTheCloseKeyAddsNoLayerAndNoMask() throws {
        let harness = Commit.Harness(Commit.screen(Self.tree(12)), focused: "p", holds: false) { $0.splitSizingOverride = .even }
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let all = screen.subviews.compactMap { $0 as? PaneHostView }.filter { !$0.isHidden }
        try #require(all.count == 12, "SETUP: the screen shows \(all.count) panes at rest, not 12")
        func layers() -> Int { all.reduce(0) { $0 + ($1.layer.map { Self.layers(in: $0).count } ?? 0) } }
        func masks() -> Int { all.filter { $0.clipView.layer?.mask != nil }.count }
        let rest = layers()
        try #require(masks() == 0, "SETUP: \(masks()) panes have a mask on their clip at rest")
        for key in 1...10 {
            let pane = try #require(harness.model.focusedPane, "SETUP: no pane has the focus before key \(key)")
            _ = try #require(harness.model.showPaneClose(pane), "SETUP: the model does not show the close of \(pane) at key \(key)")
            harness.root.syncWithModel()
            _ = harness.root.advanceFrame(Self.dt)
            try #require(Self.inFlight(screen), "SETUP: key \(key) ended the motion")
            guard key == 4 || key == 10 else { continue }
            #expect(layers() == rest, "after key \(key) the pane hosts have \(layers()) layers; at rest they had \(rest)")
            #expect(masks() == 0, "after key \(key) \(masks()) panes have a mask on their clip")
            let bare = all.filter { host in !host.isHidden && (host.layer.map { Self.move(of: $0).moves } ?? false) && (host.layer?.backgroundColor?.alpha ?? 0) < 1 }
            #expect(bare.isEmpty, "after key \(key) the panes \(bare.map(\.pane)) move with no colour of alpha 1 on their layer")
        }
    }

    /// A window that shows what is behind it (not opaque, a background with alpha below 1) has no plain colour under
    /// its panes: a close moves its panes, and no pane host gets a colour on its layer.
    @Test func inAWindowThatShowsWhatIsBehindItNoPaneGetsAColour() throws {
        let harness = Commit.Harness(Commit.pair, focused: Commit.right, holds: false)
        defer { harness.window.closeAfterTest() }
        harness.window.isOpaque = false
        harness.window.backgroundColor = NSColor.white.withAlphaComponent(0.01)
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        harness.model.apply(screens: Commit.screen(.leaf(Commit.right)))
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        try #require(Self.inFlight(screen), "SETUP: no pane moves at the close")
        let coloured = screen.subviews.compactMap { $0 as? PaneHostView }.filter { $0.layer?.backgroundColor != nil }.map(\.pane)
        #expect(coloured.isEmpty, "in a window that is not opaque the panes \(coloured) have a colour on their layer")
    }
}
