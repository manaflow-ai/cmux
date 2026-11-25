import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTestSupport
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, a second act in a move with no ground.
///
/// The pane that grows is opaque and whole in each frame; only the other panes dim. Each pane under the one pane that
/// a zoom or an unzoom moves shows only outside it: a mask with a hole on its clip (`PaneCommitMotion+Under`). A
/// second act in the move finds those masks on the clips. The key again on the same pane: each hole goes on with
/// the pane, and no other pane shows inside it. A zoom of another pane: that pane is the one that grows now, and the
/// mask of the act before is off its clip. At the motion's end no clip has a mask and no layer has a window.
extension PaneCommitMotionTests {
    /// The frames of the first act before the key of the second one.
    nonisolated static let framesBeforeTheKey = 3
    /// A zoom and an unzoom in a glass window, at each speed at which a pane moves.
    nonisolated static let glassMoves: [Look] = ["zoom", "unzoom"].flatMap { scene in
        movingSpeeds.map { Look(kind: "glass", scene: scene, speed: $0) }
    }

    /// The keys of this motion's animations on the layer of `host`.
    static func commitKeys(on host: PaneHostView) -> [String] {
        (host.layer?.animationKeys() ?? []).filter { $0.hasPrefix("pane.commit.") }.sorted()
    }

    /// What the motion left on the pane hosts of `screen`: an animation of the motion, a mask on a pane's clip, or a
    /// layer whose own coordinates do not start where they did (`origins`) or have not the size of its pane.
    static func leftovers(on screen: ScreenContentView, origins: [ObjectIdentifier: CGPoint]) -> [String] {
        var left: [String] = []
        for host in paneHosts(screen) {
            guard let layer = host.layer else { continue }
            let keys = commitKeys(on: host)
            if !keys.isEmpty { left.append("\(host.pane) has the animations \(keys)") }
            if host.clipView.layer?.mask != nil { left.append("the clip of \(host.pane) has a mask") }
            if let was = origins[ObjectIdentifier(host)], layer.bounds.origin != was {
                left.append("the layer of \(host.pane) has the origin \(layer.bounds.origin), not \(was)")
            }
            if layer.bounds.size != host.frame.size { left.append("the layer of \(host.pane) has the size \(layer.bounds.size), not \(host.frame.size)") }
        }
        return left
    }

    /// The second act, and the frame that shows it. `pane` gets its screen; nil: the screen shows its `count` panes
    /// again, and the content of `closing` (the pane that had the screen) gets a last frame for its unzoom, as
    /// ``overPicture(_:panes:gap:speed:padding:configure:before:)`` gives one for its own unzoom.
    static func secondAct(on over: OverPicture, zoomed pane: PaneID?, of count: Int, closing: PaneHostView?) throws {
        let harness = over.harness
        if let pane {
            harness.model.apply(screens: Commit.screen(.leaf(pane), zoomed: true))
        } else {
            if let closing {
                let content = try #require(harness.provider.contents[closing.pane], "SETUP: the zoomed pane has no content")
                let area = PaneContentAreaView(frame: content.bounds), last = Picture(frame: content.bounds)
                area.autoresizingMask = [.width, .height]
                last.autoresizingMask = [.width, .height]
                area.addSubview(last)
                content.addSubview(area)
            }
            harness.model.apply(screens: Commit.screen(tree(count)))
        }
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(dt)
    }

    /// The key again in a move, in a glass window: a zoom and then the unzoom 3 frames later, and an unzoom and then
    /// the zoom of the same pane. The second act moves. In each frame from the one that shows it, the pane that
    /// moves is whole and no part of another pane that shows is inside its rect: the hole of each other pane's mask
    /// goes on from where the first act's move has it, as the pane over it does (the 2 moves add up). At the
    /// motion's end no pane host has an animation of the motion or a mask on its clip, the motion keeps no cut and
    /// no window, and each host's layer has the origin that it had before the first act and its pane's size.
    @Test(arguments: glassMoves)
    func theKeyAgainInAMoveWithNoGroundShowsNoOtherPaneInsideThePaneThatMoves(_ look: Look) throws {
        var origins: [ObjectIdentifier: CGPoint] = [:]
        let over = try Self.overPicture(look.scene, panes: 6, gap: look.gap, speed: look.speed, before: { harness in
            guard let screen = harness.screen else { return }
            for host in Self.paneHosts(screen) {
                if let layer = host.layer { origins[ObjectIdentifier(host)] = layer.bounds.origin }
            }
        })
        defer { over.harness.window.closeAfterTest() }
        try Self.requireKind(look.kind, of: over)
        let screen = over.screen, harness = over.harness, motion = screen.zoomDim.motion
        let mover = try #require(Self.movers(of: look.scene, on: screen).first, "SETUP: the \(look.scene) puts no pane over another")
        let others = Self.paneHosts(screen).filter { $0 !== mover }
        let first = motion.serial, second = look.scene == "zoom" ? "unzoom" : "zoom"
        for _ in 0..<Self.framesBeforeTheKey { _ = harness.root.advanceFrame(Self.dt) }
        try #require(Self.inFlight(screen), "SETUP: no pane moves \(Self.framesBeforeTheKey) frames after the frame that showed the \(look.scene)")

        try Self.secondAct(on: over, zoomed: second == "zoom" ? mover.pane : nil, of: 6, closing: mover)
        try #require(motion.serial == first + 1, "SETUP: the \(second) in the move of the \(look.scene) shows in one frame: no second act moves")
        var faults: [String] = [], under = 0, tick = 0
        while Self.inFlight(screen), tick < 2 * Commit.frames {
            let now = tick
            let part: (Int) -> CGFloat = { act in
                act == first
                    ? Self.way(of: look.scene, at: look.speed, tick: Self.framesBeforeTheKey + 1 + now)
                    : Self.way(of: second, at: look.speed, tick: now)
            }
            let whole = Self.notWhole(mover, content: nil)
            if !whole.isEmpty { faults.append("tick \(tick), \(mover.pane): \(whole.joined(separator: "; "))") }
            if let layer = mover.layer {
                let rect = Self.rect(of: layer, at: part)
                var shows: [String] = []
                for other in others {
                    if !other.isHidden, Self.area(other.frame.intersection(rect)) >= 1 { under += 1 }
                    let inside = Self.showing(other, on: screen, at: part).reduce(CGFloat(0)) { $0 + Self.area($1.intersection(rect)) }
                    if inside >= 1 { shows.append("\(other.pane) in \(Int(inside)) pt2") }
                }
                if !shows.isEmpty { faults.append("tick \(tick), inside \(mover.pane) at \(rect): \(shows.joined(separator: ", "))") }
            }
            _ = harness.root.advanceFrame(Self.dt)
            tick += 1
        }
        try #require(!Self.inFlight(screen), "SETUP: a pane still moves \(tick) frames after the frame that showed the \(second)")
        try #require(under > 0, "SETUP: in no frame after the \(second) is the place of another pane under the pane that moves")
        #expect(faults.isEmpty, "\(faults.count) reads after the \(second) in the move of the \(look.scene) are wrong; the first: \(faults.prefix(3))")
        let left = Self.leftovers(on: screen, origins: origins)
        #expect(left.isEmpty && motion.covers.isEmpty && motion.cuts.isEmpty,
                "at the motion's end a pane host is not as before the acts: \(left.prefix(3)); the motion keeps \(motion.covers.count) windows and \(motion.cuts.count) cuts")
    }

    /// A zoom of another pane in a move, in a glass window. That pane was under the pane of the first act and has
    /// that act's mask on its clip. From the frame that shows its zoom it is the pane that grows: it is whole (no
    /// mask on it or on its clip), its layer has no animation of the act before, and the motion keeps no cut and no
    /// window for it. After an unzoom the second zoom moves. After a zoom the screen stays zoomed, and the change
    /// can show in one frame. At the motion's end no pane host has an animation of the motion or a mask on its clip.
    @Test(arguments: glassMoves)
    func aZoomOfAnotherPaneInAMoveWithNoGroundGrowsWhole(_ look: Look) throws {
        let over = try Self.overPicture(look.scene, panes: 6, gap: look.gap, speed: look.speed)
        defer { over.harness.window.closeAfterTest() }
        try Self.requireKind(look.kind, of: over)
        let screen = over.screen, harness = over.harness, motion = screen.zoomDim.motion
        let mover = try #require(Self.movers(of: look.scene, on: screen).first, "SETUP: the \(look.scene) puts no pane over another")
        for _ in 0..<Self.framesBeforeTheKey { _ = harness.root.advanceFrame(Self.dt) }
        try #require(Self.inFlight(screen), "SETUP: no pane moves \(Self.framesBeforeTheKey) frames after the frame that showed the \(look.scene)")
        let first = motion.serial
        let found = Self.paneHosts(screen).first { host in host !== mover && !host.isHidden && motion.cuts[ObjectIdentifier(host)] != nil }
        let next = try #require(found, "SETUP: no other pane has a cut in the move of the \(look.scene)")
        try #require(next.clipView.layer?.mask != nil, "SETUP: the motion keeps a cut for the pane \(next.pane), and its clip has no mask")

        harness.model.focus(next.pane, notify: false)
        try Self.secondAct(on: over, zoomed: next.pane, of: 6, closing: nil)
        if look.scene == "unzoom" {
            try #require(motion.serial == first + 1, "SETUP: the zoom of \(next.pane) in the unzoom's move shows in one frame: no second act moves")
        }
        var faults: [String] = [], tick = 0
        while tick < 2 * Commit.frames {
            var wrong = Self.notWhole(next, content: nil)
            let old = Self.commitKeys(on: next).filter { $0.hasPrefix("pane.commit.\(first).") }
            if !old.isEmpty { wrong.append("its layer has animations of the act before: \(old)") }
            if motion.covers[ObjectIdentifier(next)] != nil { wrong.append("the motion keeps a window for it") }
            if motion.cuts[ObjectIdentifier(next)] != nil { wrong.append("the motion keeps a cut for it") }
            if !wrong.isEmpty { faults.append("tick \(tick), \(next.pane): \(wrong.joined(separator: "; "))") }
            guard Self.inFlight(screen) else { break }
            _ = harness.root.advanceFrame(Self.dt)
            tick += 1
        }
        try #require(!Self.inFlight(screen), "SETUP: a pane still moves \(tick) frames after the frame that showed the zoom of \(next.pane)")
        #expect(faults.isEmpty, "\(faults.count) reads of the pane that grows after the \(look.scene) are wrong; the first: \(faults.prefix(3))")
        let left = Self.leftovers(on: screen, origins: [:])
        #expect(left.isEmpty && motion.covers.isEmpty && motion.cuts.isEmpty,
                "at the motion's end a pane host is not at rest: \(left.prefix(3)); the motion keeps \(motion.covers.count) windows and \(motion.cuts.count) cuts")
    }
}
