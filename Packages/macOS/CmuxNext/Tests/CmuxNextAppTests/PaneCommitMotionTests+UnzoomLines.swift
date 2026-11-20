import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTestSupport
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, the divider lines under the pane that an unzoom closes to its place.
///
/// The pane that grows is opaque and whole in each frame; only the other panes dim. An unzoom brings each divider of
/// its layout back in the frame that shows it, under the pane that still has the screen's size. In a window that
/// gives a pane no ground, a line under that pane would show through it. So the unzoom holds such a line back, with no
/// animation, and the motion's end shows it (`PaneCommitMotion+Lines`). The first row says that no line shows inside
/// that pane; with the lines held back it is true because no line shows at all, so the rows for the motion's end carry
/// the weight: each line shows there, at each kind of end. The rows read the animations on the layers and what a
/// divider says of its line; they read no pixels.
extension PaneCommitMotionTests {
    /// An unzoom in each kind of window, at each speed at which a pane moves.
    nonisolated static let unzoomLooks: [Look] = windowKinds.flatMap { kind in
        movingSpeeds.map { Look(kind: kind, scene: "unzoom", speed: $0) }
    }

    /// How an unzoom's motion ends: by its own time; after the zoom of the same pane in its move, and the unzoom
    /// again; after a split or a close in its move; cut.
    nonisolated static let unzoomEnds = ["plain", "the key again", "a split in the move", "a close in the move", "cut"]

    /// The rect of its screen in which the line of `view` shows when the moves of each act are at `part(act)` of
    /// their way: the line, where the animations on the view's layer put it, cut by that layer when the layer clips
    /// what is in it. Nil: the view is hidden, has the opacity 0, or draws no line now.
    static func lineShowing(_ view: DividerHandleView, at part: (Int) -> CGFloat) -> CGRect? {
        guard !view.isHidden, view.alphaValue > 0, view.isLineVisible, let layer = view.layer, layer.opacity > 0 else { return nil }
        let cell = rect(of: layer, at: part), end = move(of: layer, only: []).end
        let own = origin(of: layer, at: part), still = layer.bounds.origin
        let line = view.lineFrameInSuperview.offsetBy(dx: cell.minX - end.minX - (own.x - still.x), dy: cell.minY - end.minY - (own.y - still.y))
        let shown = layer.masksToBounds ? line.intersection(cell) : line
        return shown.isNull || shown.width <= 0 || shown.height <= 0 ? nil : shown
    }

    /// The dividers that `screen` shows now.
    static func dividers(on screen: ScreenContentView) -> [DividerHandleView] {
        screen.subviews.compactMap { $0 as? DividerHandleView }.filter { !$0.isHidden && $0.alphaValue > 0 }
    }

    /// Whether `view` has a colour for its line: it draws a line at rest.
    static func hasLine(_ view: DividerHandleView) -> Bool { (view.lineColor?.alpha ?? 0) > 0.001 }

    /// Whether the line of `view` waits: the divider has a colour for its line, and the line draws nothing.
    static func lineWaits(_ view: DividerHandleView) -> Bool { hasLine(view) && !view.isLineVisible }

    /// In the frame that shows an unzoom, in each frame of its move and at rest, no part of a divider's line that
    /// shows is inside the rect of the pane that closes to its place, unless that pane has a ground that covers its
    /// whole rect. Inside is more than 1 pt from the rect's edge: a line in the gap beside the pane's own edge is not
    /// inside the pane. A clip can take more of a line than the rect covers, never less. The row's model has its own
    /// style, the one in which each split draws its line at rest, so the row does not read the app's settings.
    @Test(arguments: unzoomLooks)
    func inAnUnzoomNoDividerLineShowsInsideThePaneThatClosesWithNoGround(_ look: Look) throws {
        let over = try Self.overPicture(look.scene, panes: 6, gap: look.gap, speed: look.speed, configure: { $0.followsDesignMetrics = false })
        try #require(over.harness.model.style.showsDividerLine, "SETUP: the row's style draws no line between split panes")
        defer { over.harness.window.closeAfterTest() }
        try Self.requireKind(look.kind, of: over)
        let screen = over.screen
        let mover = try #require(Self.movers(of: look.scene, on: screen).first, "SETUP: the unzoom puts no pane over another")
        let layer = try #require(mover.layer, "SETUP: the pane that closes has no layer")
        let lines = screen.dividerViews.values.filter { $0.superview === screen }
        // A line that the unzoom holds back draws nothing in this frame: the count is of the dividers with a line's colour.
        let drawn = lines.filter { !$0.isHidden && Self.hasLine($0) }.count
        try #require(drawn > 0, "SETUP: none of the \(lines.count) dividers on the screen has a colour for its line")
        var faults: [String] = [], bare = 0, under = 0
        let frames = try Self.eachTick(of: look, over) { frame, way, _ in
            let rect = Self.rect(of: layer, at: { _ in way }).insetBy(dx: 1, dy: 1)
            if lines.contains(where: { !$0.isHidden && Self.area($0.lineFrameInSuperview.intersection(rect)) >= 1 }) { under += 1 }
            guard !Self.hasFullGround(mover) else { return }
            if frame != "rest" { bare += 1 }
            var inside: CGFloat = 0, count = 0
            for line in lines {
                guard let shown = Self.lineShowing(line, at: { _ in way }) else { continue }
                let part = Self.area(shown.intersection(rect))
                if part >= 1 { (inside, count) = (inside + part, count + 1) }
            }
            if count > 0 { faults.append("\(frame), inside \(mover.pane) at \(rect): \(count) of \(drawn) lines, \(Int(inside)) pt2") }
        }
        try #require(under > 0, "SETUP: in no frame of the unzoom is the place of a divider's line inside the pane that closes")
        let grounded = look.kind == "still" || look.kind == "opaque"
        try #require(grounded || bare > 0, "SETUP: the pane that closes has a ground in each of the \(frames) frames, in a window of the kind `\(look.kind)`")
        #expect(faults.isEmpty, "\(faults.count) reads show a divider's line inside the pane that an unzoom closes with no ground; the first: \(faults.prefix(3))")
    }

    /// An unzoom in a glass window holds the lines of its dividers back in the frame that shows it. At the motion's
    /// end each divider that the screen shows draws its line, and no line waits, at each kind of end
    /// (``unzoomEnds``). After the key again the zoomed screen shows no line that waits, and the row goes on to the
    /// unzoom again and its end. The motion keeps no divider then.
    @Test(arguments: unzoomEnds, movingSpeeds)
    func atTheEndOfAnUnzoomsMotionEachDividerShowsItsLine(_ end: String, _ speed: MotionSpeed) throws {
        let over = try Self.overPicture("unzoom", panes: 6, gap: "glass", speed: speed, configure: { $0.followsDesignMetrics = false })
        defer { over.harness.window.closeAfterTest() }
        try #require(over.harness.model.style.showsDividerLine, "SETUP: the row's style draws no line between split panes")
        try Self.requireKind("glass", of: over)
        let screen = over.screen, harness = over.harness, motion = screen.zoomDim.motion
        let mover = try #require(Self.movers(of: "unzoom", on: screen).first, "SETUP: the unzoom puts no pane over another")
        let held = Self.dividers(on: screen).filter { Self.lineWaits($0) }.count
        try #require(held > 0, "SETUP: no line waits in the frame that shows the unzoom, of \(Self.dividers(on: screen).count) dividers")
        let first = motion.serial
        func step(_ count: Int) { for _ in 0..<count { _ = harness.root.advanceFrame(Self.dt) } }
        func rest() throws {
            var tick = 0
            while Self.inFlight(screen), tick < 2 * Commit.frames {
                step(1)
                tick += 1
            }
            try #require(!Self.inFlight(screen), "SETUP: a pane still moves \(tick) frames after the last act (`\(end)`)")
        }
        if end != "plain" {
            step(Self.framesBeforeTheKey)
            try #require(Self.inFlight(screen), "SETUP: no pane moves \(Self.framesBeforeTheKey) frames after the frame that showed the unzoom")
        }
        switch end {
        case "the key again":
            try Self.secondAct(on: over, zoomed: mover.pane, of: 6, closing: nil)
            try #require(motion.serial == first + 1, "SETUP: the zoom in the unzoom's move shows in one frame: no second act moves")
            try rest()
            let waits = Self.dividers(on: screen).filter { Self.lineWaits($0) }.count
            #expect(waits == 0, "after the zoom in the unzoom's move, \(waits) lines wait on the zoomed screen")
            // The pane's content still has the last frame that the first unzoom got: no second one.
            try Self.secondAct(on: over, zoomed: nil, of: 6, closing: nil)
            try #require(Self.inFlight(screen), "SETUP: the unzoom after the key again moves no pane")
            let again = Self.dividers(on: screen).filter { Self.lineWaits($0) }.count
            try #require(again > 0, "SETUP: no line waits in the frame that shows the unzoom after the key again")
        case "a split in the move":
            harness.model.apply(screens: Commit.screen(Self.tree(7)))
            harness.root.syncWithModel()
            step(1) // the split moves its panes, or it shows in one frame and ends the motion: each is an end
        case "a close in the move":
            _ = try #require(harness.model.showPaneClose(PaneID("pbab")), "SETUP: the model does not show the close of a pane")
            harness.root.syncWithModel()
            step(1)
            try #require(motion.serial == first + 1, "SETUP: the close in the unzoom's move shows in one frame: no second act moves")
        case "cut":
            screen.zoomDim.end()
        default:
            break
        }
        try rest()
        let lines = Self.dividers(on: screen).filter { Self.hasLine($0) }
        try #require(!lines.isEmpty, "SETUP: at the end (`\(end)`) the screen shows no divider with a colour for its line")
        let dark = lines.filter { Self.lineWaits($0) || Self.lineShowing($0, at: { _ in 1 }) == nil }.count
        #expect(dark == 0, "at the end (`\(end)`) \(dark) of \(lines.count) dividers draw no line; \(held) lines waited in the frame that showed the unzoom")
        #expect(motion.lateLines.isEmpty, "at the end (`\(end)`) the motion still keeps \(motion.lateLines.count) dividers")
    }

    /// With the panes' move off, an unzoom in a glass window shows each divider's line in the frame that shows it:
    /// no pane closes over the lines, so no line waits.
    @Test
    func withThePanesMoveOffAnUnzoomShowsEachDividersLineAtOnce() throws {
        let over = try Self.overPicture("zoom", panes: 6, gap: "glass", speed: .normal, configure: { $0.followsDesignMetrics = false })
        defer { over.harness.window.closeAfterTest() }
        try #require(over.harness.model.style.showsDividerLine, "SETUP: the row's style draws no line between split panes")
        try Self.requireKind("glass", of: over)
        let screen = over.screen, harness = over.harness
        let mover = try #require(Self.movers(of: "zoom", on: screen).first, "SETUP: the zoom puts no pane over another")
        Commit.rest(harness)
        try #require(!Self.inFlight(screen), "SETUP: the zoom did not come to rest")
        harness.root.context.commitMotionOverride = false
        try Self.secondAct(on: over, zoomed: nil, of: 6, closing: mover)
        // The unzoom can wait some frames for its panes' content: each frame from its turn is read.
        var waits = 0, frames = 0
        while frames < 8 {
            try #require(!Self.inFlight(screen), "SETUP: a pane moves in an unzoom with the panes' move off")
            waits += Self.dividers(on: screen).filter { Self.lineWaits($0) }.count
            _ = harness.root.advanceFrame(Self.dt)
            frames += 1
        }
        let lines = Self.dividers(on: screen).filter { Self.hasLine($0) }
        try #require(!lines.isEmpty, "SETUP: \(frames) frames after the unzoom the screen shows no divider with a colour for its line")
        let dark = lines.filter { Self.lineShowing($0, at: { _ in 1 }) == nil }.count
        #expect(waits == 0, "with the panes' move off, \(waits) reads in \(frames) frames show a divider's line that waits")
        #expect(dark == 0, "with the panes' move off, \(dark) of \(lines.count) dividers draw no line \(frames) frames after the unzoom")
    }

    /// A close and a split in a glass window hold no line back: in the frame that shows the act, in each frame of its
    /// move and at rest, no divider that the screen shows has a colour for its line and draws nothing. Only an
    /// unzoom's dividers wait.
    @Test(arguments: ["close", "split, held"], movingSpeeds)
    func aMoveThatIsNoUnzoomHoldsNoDividersLineBack(_ scene: String, _ speed: MotionSpeed) throws {
        let look = Look(kind: "glass", scene: scene, speed: speed)
        let over = try Self.overPicture(look.scene, panes: 6, gap: look.gap, speed: look.speed, configure: { $0.followsDesignMetrics = false })
        defer { over.harness.window.closeAfterTest() }
        try #require(over.harness.model.style.showsDividerLine, "SETUP: the row's style draws no line between split panes")
        try Self.requireKind(look.kind, of: over)
        let screen = over.screen
        var faults: [String] = [], read = 0
        let frames = try Self.eachTick(of: look, over) { frame, _, _ in
            let lines = Self.dividers(on: screen).filter { Self.hasLine($0) }
            read += lines.count
            let waits = lines.filter { Self.lineWaits($0) }.count
            if waits > 0 { faults.append("\(frame): \(waits) of \(lines.count) lines") }
        }
        // A split that shows in one frame is read in that frame: it holds no line back either.
        try #require(frames > 0 || scene != "close", "SETUP: the close moves no pane")
        try #require(read > 0, "SETUP: in no frame of the \(scene) does the screen show a divider with a colour for its line")
        print("LINES ROW: \(scene), \(speed): \(frames) frames of a move read, \(read) reads of a divider with a line's colour")
        #expect(faults.isEmpty, "\(faults.count) reads of a \(scene) show a divider's line that waits; the first: \(faults.prefix(3))")
    }

    /// An unzoom in a window that gives the pane that closes a ground (one still picture, an opaque window) holds no
    /// line back: the ground covers each line under the pane. In the frame that shows the unzoom, in each frame of its
    /// move and at rest, no divider that the screen shows has a colour for its line and draws nothing, and the motion
    /// keeps no divider.
    @Test(arguments: ["still", "opaque"], movingSpeeds)
    func anUnzoomOverAGroundHoldsNoDividersLineBack(_ kind: String, _ speed: MotionSpeed) throws {
        let look = Look(kind: kind, scene: "unzoom", speed: speed)
        let over = try Self.overPicture(look.scene, panes: 6, gap: look.gap, speed: look.speed, configure: { $0.followsDesignMetrics = false })
        defer { over.harness.window.closeAfterTest() }
        try #require(over.harness.model.style.showsDividerLine, "SETUP: the row's style draws no line between split panes")
        try Self.requireKind(look.kind, of: over)
        let screen = over.screen, motion = screen.zoomDim.motion
        try #require(Self.inFlight(screen), "SETUP: no pane moves in the frame that shows the unzoom")
        var faults: [String] = [], read = 0, kept = 0
        let frames = try Self.eachTick(of: look, over) { frame, _, _ in
            let lines = Self.dividers(on: screen).filter { Self.hasLine($0) }
            read += lines.count
            kept += motion.lateLines.count
            let waits = lines.filter { Self.lineWaits($0) }.count
            if waits > 0 { faults.append("\(frame): \(waits) of \(lines.count) lines") }
        }
        try #require(read > 0, "SETUP: in no frame of the unzoom does the screen show a divider with a colour for its line")
        print("LINES ROW: unzoom, \(kind), \(speed): \(frames) frames of a move read, \(read) reads of a divider with a line's colour")
        #expect(faults.isEmpty, "\(faults.count) reads of an unzoom over a ground show a divider's line that waits; the first: \(faults.prefix(3))")
        #expect(kept == 0, "in an unzoom over a ground the motion keeps a divider in \(kept) reads")
    }
}
