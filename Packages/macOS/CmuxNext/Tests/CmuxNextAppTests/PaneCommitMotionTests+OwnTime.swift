import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTestSupport
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, a second act in a close's move with no ground, and the read of 2 acts in one move with
/// each animation at its own time.
///
/// The pane that grows is opaque and whole in each frame; only the other panes dim. A second act in a move puts its
/// animations on layers that still have the ones of the act before, and the 2 acts have 2 clocks. The reads of this
/// file give each animation the time since the frame that showed its own act, with the animation's own spring and
/// duration. A hole of a mask that is not at the rect of the pane over it in a frame makes a row red.
extension PaneCommitMotionTests {
    /// Where `layer` shows in its superlayer when each animation of its position and size is `since(act)` seconds
    /// after the frame that showed its act (``spent(of:after:)``). The act is the number in the animation's key
    /// (``act(of:)``); an animation with no such number counts for the newest act. An animation that adds to the
    /// value adds; another one replaces it.
    static func rectByOwnTime(of layer: CALayer, since: (Int) -> Double) -> CGRect {
        var values = [layer.position.x, layer.position.y, layer.bounds.width, layer.bounds.height]
        for key in layer.animationKeys() ?? [] {
            guard let animation = layer.animation(forKey: key) as? CABasicAnimation, let path = animation.keyPath,
                  path.hasPrefix("position") || path.hasPrefix("bounds") else { continue }
            let part = spent(of: animation, after: since(Self.act(of: key) ?? Int.max))
            let from = numbers(animation.fromValue, of: path), to = numbers(animation.toValue, of: path)
            for index in 0..<4 {
                guard let start = from[index] ?? to[index], let end = to[index] ?? from[index] else { continue }
                values[index] = (animation.isAdditive ? values[index] : 0) + start + (end - start) * part
            }
        }
        let anchor = layer.anchorPoint
        return CGRect(x: values[0] - anchor.x * values[2], y: values[1] - anchor.y * values[3], width: values[2], height: values[3])
    }

    /// What the screen shows of `host` on `screen`, by its own layers alone (no pane over it counts), with each
    /// animation at its own time (``rectByOwnTime(of:since:)``): its clip in its layer's rect, as far as the mask on
    /// that clip leaves it. Each part of the mask is where its own animations put it. A pane that is hidden or has
    /// the opacity 0 shows in no part. A window on the pane's own layer is not read.
    static func keptByOwnTime(_ host: PaneHostView, on screen: ScreenContentView, since: (Int) -> Double) -> Kept {
        let rect = host.layer.map { Self.rectByOwnTime(of: $0, since: since) } ?? host.frame
        let dx = rect.minX - host.frame.minX, dy = rect.minY - host.frame.minY
        func onScreen(_ rect: CGRect) -> CGRect { screen.convert(rect, from: host.clipView).offsetBy(dx: dx, dy: dy) }
        var clip = onScreen(host.clipView.bounds)
        if let inner = host.clipView.layer {
            let now = Self.rectByOwnTime(of: inner, since: since), rest = move(of: inner, only: []).end
            clip = CGRect(x: clip.minX + now.minX - rest.minX, y: clip.minY + now.minY - rest.minY,
                          width: clip.width + now.width - rest.width, height: clip.height + now.height - rest.height)
        }
        let shows = clip.intersection(rect)
        var kept = Kept(shows: shows, parts: [shows])
        if host.isHidden || host.alphaValue <= 0 || (host.layer?.opacity ?? 0) <= 0 {
            kept.parts = []
        } else if let mask = host.clipView.layer?.mask {
            let frame = mask.frame, origin = mask.bounds.origin
            var parts: [CGRect] = []
            for part in mask.sublayers ?? [] where part.backgroundColor != nil {
                let inClip = Self.rectByOwnTime(of: part, since: since).offsetBy(dx: frame.minX - origin.x, dy: frame.minY - origin.y)
                let piece = onScreen(inClip).intersection(shows)
                if !piece.isNull { parts.append(piece) }
            }
            kept.parts = parts
        }
        return kept
    }

    /// A close in a glass window, and in its move the close of the pane that the first close made grow: ONE pane
    /// takes its room, the one pane that grows now. The pane of the second close is under it, and it still had its
    /// own move of the first close. In each frame from the one that shows the second close:
    /// 1. The pane of the second close is at its place at rest: its own move ends in the pass that shows the second
    ///    close, so the mask that this close puts on its clip is on a pane at rest. The eye gets that pane at its
    ///    place in one frame.
    /// 2. No part of that pane that shows is inside the rect of the pane that grows.
    /// 3. By its clip and the mask on that clip, that pane shows in each part of its place outside that rect.
    /// 4. No part of another pane that shows is inside the rect of the pane that grows; the pane of the first close
    ///    is not in this check.
    ///
    /// THE PANE OF THE FIRST CLOSE IS NOT CHECKED. It is under the 2 panes that move, one after the other. Its mask
    /// of the first close is used again for the second close, and the hole's move of the first close stays on that
    /// mask: until that move's end the hole is not at the rect of the pane that grows, and a band of the pane of
    /// the first close can show inside the pane that grows. This is a known limit of a mask that 2 acts use, and no
    /// check of this row sees it. The row prints it and puts no bound on it: for each frame the area of that pane
    /// that shows inside the pane that grows, in pt2 and as a part of the window's content, and the count of frames
    /// with an area above 0. The row prints the jump of the pane of the second close too.
    @Test(arguments: movingSpeeds)
    func aCloseWithOnePaneThatGrowsInAClosesMoveShowsItsPaneOnlyOutsideIt(_ speed: MotionSpeed) throws {
        let over = try Self.overPicture("close", panes: 6, gap: "glass", speed: speed)
        defer { over.harness.window.closeAfterTest() }
        try Self.requireKind("glass", of: over)
        let screen = over.screen, harness = over.harness, motion = screen.zoomDim.motion
        let grown = Self.movers(of: "close", on: screen)
        try #require(grown.count == 1, "SETUP: the first close makes \(grown.count) panes grow, not 1")
        let second = grown[0]
        let gone = try #require(Self.paneHosts(screen).first { $0.isLeaving && !$0.isHidden }, "SETUP: the first close keeps no pane under the pane that takes its room")
        for _ in 0..<Self.framesBeforeTheKey { _ = harness.root.advanceFrame(Self.dt) }
        try #require(Self.inFlight(screen), "SETUP: no pane moves \(Self.framesBeforeTheKey) frames after the frame that showed the first close")
        let first = motion.serial
        let jump = Self.edgesFromRest(second, at: { _ in Self.way(of: "close", at: speed, tick: Self.framesBeforeTheKey) })
        try #require(jump > 0.5, "SETUP: \(second.pane) is at its place \(Self.framesBeforeTheKey) frames into the first close's move")
        let window = Self.area(harness.root.bounds)
        try #require(window > 1, "SETUP: the window's content has no area")

        _ = try #require(harness.model.showPaneClose(second.pane), "SETUP: the model does not show the close of \(second.pane)")
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        try #require(motion.serial == first + 1, "SETUP: the close of \(second.pane) in the first close's move shows in one frame: no second act moves")
        try #require(second.isLeaving && !second.isHidden, "SETUP: the move does not keep \(second.pane) under the pane that takes its room")
        let grows = Self.movers(of: "close", on: screen)
        try #require(grows.count == 1, "SETUP: the second close makes \(grows.count) panes grow, not 1")
        let next = grows[0], layer = try #require(next.layer, "SETUP: the pane that grows has no layer")
        try #require(!Self.hasFullGround(next), "SETUP: the pane that grows has a ground in a glass window")
        let others = Self.paneHosts(screen).filter { $0 !== next && $0 !== second && $0 !== gone }
        var away: [String] = [], inside: [String] = [], taken: [String] = [], faults: [String] = [], band: [String] = []
        var under = 0, tick = 0, banded = 0, wide = 0, most: CGFloat = 0
        while Self.inFlight(screen), tick < 2 * Commit.frames {
            let now = tick
            let part: (Int) -> CGFloat = { act in
                Self.way(of: "close", at: speed, tick: act == first ? Self.framesBeforeTheKey + 1 + now : now)
            }
            let since: (Int) -> Double = { act in Double(act == first ? Self.framesBeforeTheKey + 1 + now : now) * Self.dt }
            let rect = Self.rectByOwnTime(of: layer, since: since)
            if Self.area(second.frame.intersection(rect)) >= 1 { under += 1 }
            let seen = Self.keptByOwnTime(second, on: screen, since: since)
            let within = seen.area(in: rect)
            let room = Self.area(seen.shows) - Self.area(seen.shows.intersection(rect))
            let lost = room - (seen.area(in: seen.shows) - within)
            if within >= 1 { inside.append("tick \(tick): \(Int(within)) pt2 inside \(next.pane) at \(rect)") }
            if lost > 1 { taken.append("tick \(tick): \(Int(lost)) pt2 of the \(Int(room)) pt2 outside \(next.pane)") }
            let far = Self.awayFromRest(second, on: screen, at: part)
            if far > 0.5 { away.append("tick \(tick): \((far * 10).rounded() / 10) pt") }
            var shows: [String] = []
            for other in others where !other.isHidden {
                let shown = Self.keptByOwnTime(other, on: screen, since: since).area(in: rect)
                if shown >= 1 { shows.append("\(other.pane) in \(Int(shown)) pt2") }
            }
            if !shows.isEmpty { faults.append("tick \(tick), inside \(next.pane) at \(rect): \(shows.joined(separator: ", "))") }
            // The pane of the first close: read and printed, not checked (the row's doc says why).
            let old = Self.keptByOwnTime(gone, on: screen, since: since).area(in: rect)
            if old > 0 { banded += 1 }
            if old >= 1 { wide += 1 }
            most = max(most, old)
            band.append("\(Int(old.rounded())) pt2 = \((old / window * 100_000).rounded() / 100_000)")
            _ = harness.root.advanceFrame(Self.dt)
            tick += 1
        }
        try #require(!Self.inFlight(screen), "SETUP: a pane still moves \(tick) frames after the frame that showed the close of \(second.pane)")
        try #require(under > 0, "SETUP: in no frame after the second close is the place of \(second.pane) under the pane that grows")
        print("ROW (CLOSE IN A CLOSE): \(speed), the close of \(second.pane) in the close of \(gone.pane), \(next.pane) grows: in the frame before,",
              "\(second.pane) is \((jump * 10).rounded() / 10) pt from its place (the jump); frames read: \(tick); frames with \(second.pane) not at its",
              "place: \(away.count). NOT CHECKED: the area of \(gone.pane), the pane of the first close, that shows inside \(next.pane), for each frame,",
              "in pt2 and as a part of the window's content: \(band); frames with an area above 0: \(banded); frames with 1 pt2 or more: \(wide);",
              "the most: \(Int(most.rounded())) pt2 = \((most / window * 100_000).rounded() / 100_000)")
        #expect(away.isEmpty, "(1) in \(away.count) frames from the one that shows the close of \(second.pane), \(second.pane) is not at its place; the first: \(away.prefix(3))")
        #expect(inside.isEmpty, "(2) in \(inside.count) frames \(second.pane), the pane of the second close, shows inside the pane that grows; the first: \(inside.prefix(3))")
        #expect(taken.isEmpty, "(3) in \(taken.count) frames \(second.pane) does not show in each part of its place outside the pane that grows; the first: \(taken.prefix(3))")
        #expect(faults.isEmpty, "(4) \(faults.count) reads after the close of \(second.pane) in the first close's move show another pane inside the pane that grows; the first: \(faults.prefix(3))")
    }

    /// The 5 panes that 6 panes keep after the close of the first one: the zoom in that close's move is of one of them.
    nonisolated static let fiveAfterAClose = ["paab", "pab", "pb", "pbab", "pbb"]

    /// A close in a glass window, and in its move the zoom of a pane (`name`). The pane that the close took out
    /// still shows under the pane that takes its room, and a zoom moves only when the panes that still show and
    /// leave are the panes that it covers and no other. So this zoom shows in one frame, and that frame ends the
    /// close's move:
    /// 1. The frame that shows the zoom starts no move, and no pane moves in it or in a later frame.
    /// 2. In that frame and in each later frame the pane that grows is whole (no mask on it or on its clip), its
    ///    layer has no animation of the act before, and the motion keeps no cut and no window for it.
    /// 3. In that frame and in each later frame no part of another pane that shows is inside the rect of the pane
    ///    that grows.
    /// 4. After the frames of the close's move no pane host has an animation of the motion or a mask on its clip.
    ///
    /// The row reads as many frames after the zoom as a move can take. If the zoom moves, checks 2 and 3 read each
    /// frame of its move, with each animation at its own time.
    @Test(arguments: movingSpeeds, fiveAfterAClose)
    func aZoomInAClosesMoveShowsInOneFrameAndGrowsWhole(_ speed: MotionSpeed, _ name: String) throws {
        let over = try Self.overPicture("close", panes: 6, gap: "glass", speed: speed)
        defer { over.harness.window.closeAfterTest() }
        try Self.requireKind("glass", of: over)
        let screen = over.screen, harness = over.harness, motion = screen.zoomDim.motion
        let gone = try #require(Self.paneHosts(screen).first { $0.isLeaving && !$0.isHidden }, "SETUP: the close keeps no pane under the pane that takes its room")
        for _ in 0..<Self.framesBeforeTheKey { _ = harness.root.advanceFrame(Self.dt) }
        try #require(Self.inFlight(screen), "SETUP: no pane moves \(Self.framesBeforeTheKey) frames after the frame that showed the close")
        try #require(gone.isLeaving && !gone.isHidden, "SETUP: \(gone.pane), the pane that the close took out, does not show \(Self.framesBeforeTheKey) frames into the close's move")
        let first = motion.serial
        let found = Self.paneHosts(screen).first { host in !host.isLeaving && !host.isHidden && host.pane == PaneID(name) }
        let next = try #require(found, "SETUP: the screen shows no pane `\(name)` in the close's move")

        harness.model.focus(next.pane, notify: false)
        try Self.secondAct(on: over, zoomed: next.pane, of: 6, closing: nil)
        try #require(screen.zoomed && !motion.waits, "SETUP: the frame after the zoom's key does not show the zoom of \(next.pane)")
        let started = motion.serial - first
        var faults: [String] = [], inside: [String] = [], moving = 0, tick = 0
        while tick < Commit.frames {
            let now = tick
            let since: (Int) -> Double = { act in Double(act == first ? Self.framesBeforeTheKey + 1 + now : now) * Self.dt }
            var wrong = Self.notWhole(next, content: nil)
            let old = Self.commitKeys(on: next).filter { $0.hasPrefix("pane.commit.\(first).") }
            if !old.isEmpty { wrong.append("its layer has animations of the act before: \(old)") }
            if motion.covers[ObjectIdentifier(next)] != nil { wrong.append("the motion keeps a window for it") }
            if motion.cuts[ObjectIdentifier(next)] != nil { wrong.append("the motion keeps a cut for it") }
            if !wrong.isEmpty { faults.append("tick \(tick), \(next.pane): \(wrong.joined(separator: "; "))") }
            if Self.inFlight(screen) { moving += 1 }
            if let layer = next.layer {
                let rect = Self.rectByOwnTime(of: layer, since: since)
                var shows: [String] = []
                for other in Self.paneHosts(screen) where other !== next && !other.isHidden {
                    let shown = Self.keptByOwnTime(other, on: screen, since: since).area(in: rect)
                    if shown >= 1 { shows.append("\(other.pane) in \(Int(shown)) pt2") }
                }
                if !shows.isEmpty { inside.append("tick \(tick), inside \(next.pane) at \(rect): \(shows.joined(separator: ", "))") }
            }
            _ = harness.root.advanceFrame(Self.dt)
            tick += 1
        }
        print("ROW (ZOOM IN A CLOSE): \(speed), the zoom of \(next.pane) in the close of \(gone.pane): moves that the zoom's frame started: \(started);",
              "frames read: \(tick); frames in which a pane moves: \(moving); frames with the pane that grows not whole: \(faults.count);",
              "frames with another pane inside it: \(inside.count)")
        #expect(started == 0 && moving == 0,
                "(1) the zoom of \(next.pane) in the close's move does not show in one frame: its frame started \(started) moves, and a pane moves in \(moving) of the \(tick) frames read")
        #expect(faults.isEmpty, "(2) in \(faults.count) frames the pane that grows is not whole; the first: \(faults.prefix(3))")
        #expect(inside.isEmpty, "(3) in \(inside.count) frames another pane shows inside the pane that grows; the first: \(inside.prefix(3))")
        let left = Self.leftovers(on: screen, origins: [:])
        #expect(left.isEmpty && motion.covers.isEmpty && motion.cuts.isEmpty,
                "(4) after the frames read a pane host is not at rest: \(left.prefix(3)); the motion keeps \(motion.covers.count) windows and \(motion.cuts.count) cuts")
    }
}
