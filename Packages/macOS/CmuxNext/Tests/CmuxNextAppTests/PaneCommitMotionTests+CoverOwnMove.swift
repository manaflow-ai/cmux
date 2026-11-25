import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTestSupport
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, a second act in a move with no ground that gives a pane with a cut a move of its own,
/// and the light of the other panes over 2 acts.
///
/// The pane that grows is opaque and whole in each frame; only the other panes dim. A cut of an act before (a mask
/// under one pane that moves, `PaneCommitMotion+Under`; a window under several, `PaneCommitMotion+Cover`) is made
/// for the place that its pane had then. A second act that moves that pane, or that takes it back, takes the cut
/// off it: the pane is not cut at a place that is not its own.
extension PaneCommitMotionTests {
    /// What is wrong with `host`, a pane that had a cut of an act before and has a move of its own now, or is back
    /// in the layout: it does not show, it or its clip has a mask, or the motion keeps a cut or a window for it.
    static func stillCut(_ host: PaneHostView, by motion: PaneCommitMotion) -> [String] {
        var wrong: [String] = []
        if host.isHidden || host.layer?.isHidden ?? true { wrong.append("it does not show") }
        if host.layer?.mask != nil || host.clipView.layer?.mask != nil { wrong.append("it has a mask") }
        if motion.cuts[ObjectIdentifier(host)] != nil { wrong.append("the motion keeps a cut for it") }
        if motion.covers[ObjectIdentifier(host)] != nil { wrong.append("the motion keeps a window for it") }
        return wrong
    }

    /// An unzoom in a glass window, and in its move the close of another pane. The pane that takes the room of the
    /// closed one was under the pane that the unzoom closes, and has that act's mask on its clip. From the frame
    /// that shows the close it has a move of its own: it shows with no mask, and the motion keeps no cut and no
    /// window for it. So it is not cut at a place that is not its own; and it shows under the pane that the unzoom
    /// still closes, to the motion's end (a known limit). At the motion's end no pane host has an animation of the
    /// motion or a mask on its clip.
    @Test(arguments: movingSpeeds)
    func aPaneThatGetsItsOwnMoveInAnUnzoomsMoveKeepsNoCut(_ speed: MotionSpeed) throws {
        let over = try Self.overPicture("unzoom", panes: 6, gap: "glass", speed: speed)
        defer { over.harness.window.closeAfterTest() }
        try Self.requireKind("glass", of: over)
        let screen = over.screen, harness = over.harness, motion = screen.zoomDim.motion
        let mover = try #require(Self.movers(of: "unzoom", on: screen).first, "SETUP: the unzoom puts no pane over another")
        for _ in 0..<Self.framesBeforeTheKey { _ = harness.root.advanceFrame(Self.dt) }
        try #require(Self.inFlight(screen), "SETUP: no pane moves \(Self.framesBeforeTheKey) frames after the frame that showed the unzoom")
        let first = motion.serial, gone = PaneID("pbab")
        try #require(mover.pane != gone, "SETUP: the pane that the unzoom closes is the pane of the second act")
        // The panes that the unzoom cut: the motion keeps a cut for each, and its clip has the mask.
        let had = Self.paneHosts(screen).filter { host in
            host !== mover && !host.isHidden && motion.cuts[ObjectIdentifier(host)] != nil && host.clipView.layer?.mask != nil
        }

        _ = try #require(harness.model.showPaneClose(gone), "SETUP: the model does not show the close of \(gone)")
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        try #require(motion.serial == first + 1, "SETUP: the close in the unzoom's move shows in one frame: no second act moves")
        let own = had.filter { host in
            !host.isLeaving && Self.commitKeys(on: host).contains { $0.hasPrefix("pane.commit.\(first + 1).") }
        }
        try #require(!own.isEmpty, "SETUP: the close moves no pane that had a cut of the unzoom")
        var faults: [String] = [], tick = 0
        while tick < 2 * Commit.frames {
            for host in own {
                let wrong = Self.stillCut(host, by: motion)
                if !wrong.isEmpty { faults.append("tick \(tick), \(host.pane): \(wrong.joined(separator: "; "))") }
            }
            guard Self.inFlight(screen) else { break }
            _ = harness.root.advanceFrame(Self.dt)
            tick += 1
        }
        try #require(!Self.inFlight(screen), "SETUP: a pane still moves \(tick) frames after the frame that showed the close")
        #expect(faults.isEmpty, "\(faults.count) reads of a pane with its own move in the unzoom's move are wrong; the first: \(faults.prefix(3))")
        let left = Self.leftovers(on: screen, origins: [:])
        #expect(left.isEmpty && motion.covers.isEmpty && motion.cuts.isEmpty,
                "at the motion's end a pane host is not at rest: \(left.prefix(3)); the motion keeps \(motion.covers.count) windows and \(motion.cuts.count) cuts")
    }

    /// A close in a glass window, and in its move the close is taken back. The pane that left was kept under the
    /// one pane that took its room, and has the close's mask on its clip: a mask that ends with nothing of the pane
    /// in sight under that pane. From the frame that shows the pane again it shows with no mask, and the motion
    /// keeps no cut and no window for it. At the motion's end no pane host has an animation of the motion or a mask
    /// on its clip.
    @Test(arguments: movingSpeeds)
    func aCloseTakenBackInItsMoveLeavesNoCutOnItsPane(_ speed: MotionSpeed) throws {
        let over = try Self.overPicture("close", panes: 6, gap: "glass", speed: speed)
        defer { over.harness.window.closeAfterTest() }
        try Self.requireKind("glass", of: over)
        let screen = over.screen, harness = over.harness, motion = screen.zoomDim.motion
        let gone = try #require(Self.paneHosts(screen).first { $0.isLeaving }, "SETUP: the close keeps no pane under the others")
        for _ in 0..<Self.framesBeforeTheKey { _ = harness.root.advanceFrame(Self.dt) }
        try #require(Self.inFlight(screen), "SETUP: no pane moves \(Self.framesBeforeTheKey) frames after the frame that showed the close")
        let first = motion.serial, pane = gone.pane
        try #require(motion.cuts[ObjectIdentifier(gone)] != nil, "SETUP: the pane that leaves has no cut in the close's move")
        try #require(gone.clipView.layer?.mask != nil, "SETUP: the motion keeps a cut for the pane that leaves, and its clip has no mask")

        try #require(harness.model.withdrawPaneClose(pane), "SETUP: the model has no close of \(pane) to take back")
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        try #require(motion.serial == first + 1, "SETUP: the close taken back shows in one frame: no second act moves")
        let found = Self.paneHosts(screen).first { $0.pane == pane && !$0.isLeaving && !$0.isHidden }
        let back = try #require(found, "SETUP: the screen does not show \(pane) again")
        var faults: [String] = [], tick = 0
        while tick < 2 * Commit.frames {
            let wrong = Self.stillCut(back, by: motion)
            if !wrong.isEmpty { faults.append("tick \(tick), \(pane): \(wrong.joined(separator: "; "))") }
            guard Self.inFlight(screen) else { break }
            _ = harness.root.advanceFrame(Self.dt)
            tick += 1
        }
        try #require(!Self.inFlight(screen), "SETUP: a pane still moves \(tick) frames after the frame that showed \(pane) again")
        #expect(faults.isEmpty, "\(faults.count) reads of the pane that comes back are wrong; the first: \(faults.prefix(3))")
        let left = Self.leftovers(on: screen, origins: [:])
        #expect(left.isEmpty && motion.covers.isEmpty && motion.cuts.isEmpty,
                "at the motion's end a pane host is not at rest: \(left.prefix(3)); the motion keeps \(motion.covers.count) windows and \(motion.cuts.count) cuts")
    }

    /// How far `host` is from its place at rest, in points, when the moves of each act are at `part(act)` of their
    /// way: how far its content is from where it is at rest, and how far a part of the pane that shows is past an
    /// edge of its rect at rest; the larger of them. A window on the pane gives 0: it keeps the content where it
    /// is, and the pane shows only inside its rect. The window's own rect can go past the pane's far edge, where
    /// the pane has nothing: that is not read as a pane that is not at its place.
    static func awayFromRest(_ host: PaneHostView, on screen: ScreenContentView, at part: (Int) -> CGFloat) -> CGFloat {
        guard let layer = host.layer else { return 0 }
        let cell = rect(of: layer, at: part), end = move(of: layer, only: []).end
        let own = origin(of: layer, at: part), still = layer.bounds.origin
        var far = max(abs(cell.minX - end.minX - (own.x - still.x)), abs(cell.minY - end.minY - (own.y - still.y)))
        for shown in showing(host, on: screen, at: part) {
            far = max(far, end.minX - shown.minX, end.minY - shown.minY, shown.maxX - end.maxX, shown.maxY - end.maxY)
        }
        return far
    }

    /// How far an edge of the layer of `host` is from its place at rest, in points, at `part`: the largest of its 4 edges.
    static func edgesFromRest(_ host: PaneHostView, at part: (Int) -> CGFloat) -> CGFloat {
        guard let layer = host.layer else { return 0 }
        let cell = rect(of: layer, at: part), end = move(of: layer, only: []).end
        return max(abs(cell.minX - end.minX), abs(cell.minY - end.minY), abs(cell.maxX - end.maxX), abs(cell.maxY - end.maxY))
    }

    /// A close in a glass window, and in its move the close of a pane that the first close made grow. The move keeps
    /// that pane under the panes that take its room (more than one: the way of `PaneCommitMotion+Cover`), and it
    /// still had its own move: that move ends in the pass that shows the second close, so the pane is at its place
    /// in one frame. In each frame from the one that shows the
    /// second close, no part of another pane that shows is inside the rect of a pane that grows, and each pane that
    /// the move keeps under and that had its own move is at its place. The row prints how far each such pane was from
    /// its place in the frame before, and how much of one pane that left shows inside another pane that left.
    @Test(arguments: movingSpeeds)
    func aSecondCloseInAClosesMoveShowsNoOtherPaneInsideAPaneThatGrows(_ speed: MotionSpeed) throws {
        let over = try Self.overPicture("close", panes: 7, gap: "glass", speed: speed)
        defer { over.harness.window.closeAfterTest() }
        try Self.requireKind("glass", of: over)
        let screen = over.screen, harness = over.harness, motion = screen.zoomDim.motion
        let grown = Self.movers(of: "close", on: screen).sorted { "\($0.pane)" < "\($1.pane)" }
        let second = try #require(grown.first, "SETUP: the first close makes no pane grow")
        for _ in 0..<Self.framesBeforeTheKey { _ = harness.root.advanceFrame(Self.dt) }
        try #require(Self.inFlight(screen), "SETUP: no pane moves \(Self.framesBeforeTheKey) frames after the frame that showed the first close")
        let first = motion.serial
        // A pane with a window (one under several panes that grow) has no move of its own: its layer's rect is its window.
        var jumps: [ObjectIdentifier: CGFloat] = [:]
        for host in Self.paneHosts(screen) where !host.isHidden && motion.covers[ObjectIdentifier(host)] == nil {
            jumps[ObjectIdentifier(host)] = Self.edgesFromRest(host, at: { _ in Self.way(of: "close", at: speed, tick: Self.framesBeforeTheKey) })
        }
        try #require((jumps[ObjectIdentifier(second)] ?? 0) > 0.5, "SETUP: \(second.pane) is at its place \(Self.framesBeforeTheKey) frames into the first close's move")

        _ = try #require(harness.model.showPaneClose(second.pane), "SETUP: the model does not show the close of \(second.pane)")
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        try #require(motion.serial == first + 1, "SETUP: the close of \(second.pane) in the first close's move shows in one frame: no second act moves")
        try #require(second.isLeaving && !second.isHidden, "SETUP: the move does not keep \(second.pane) under the panes that take its room")
        let left = Self.paneHosts(screen).filter { $0.isLeaving && !$0.isHidden }
        let grows = Self.movers(of: "close", on: screen)
        try #require(grows.count > 1, "SETUP: the second close makes \(grows.count) panes grow, not more than 1")
        try #require(!grows.contains { Self.hasFullGround($0) }, "SETUP: a pane that grows has a ground in a glass window")
        let others = Self.paneHosts(screen).filter { host in !grows.contains { $0 === host } }
        var faults: [String] = [], away: [String] = [], under = 0, tick = 0, mixed = 0, most: CGFloat = 0
        while Self.inFlight(screen), tick < 2 * Commit.frames {
            let now = tick
            let part: (Int) -> CGFloat = { act in
                Self.way(of: "close", at: speed, tick: act == first ? Self.framesBeforeTheKey + 1 + now : now)
            }
            for pane in grows {
                guard let layer = pane.layer else { continue }
                let rect = Self.rect(of: layer, at: part)
                var shows: [String] = []
                for other in others {
                    if !other.isHidden, Self.area(other.frame.intersection(rect)) >= 1 { under += 1 }
                    let inside = Self.showing(other, on: screen, at: part).reduce(CGFloat(0)) { $0 + Self.area($1.intersection(rect)) }
                    if inside >= 1 { shows.append("\(other.pane) in \(Int(inside)) pt2") }
                }
                if !shows.isEmpty { faults.append("tick \(tick), inside \(pane.pane) at \(rect): \(shows.joined(separator: ", "))") }
            }
            for host in left where (jumps[ObjectIdentifier(host)] ?? 0) > 0.5 {
                let far = Self.awayFromRest(host, on: screen, at: part)
                if far > 0.5 { away.append("tick \(tick), \(host.pane): \((far * 10).rounded() / 10) pt") }
            }
            var both: CGFloat = 0
            for (index, one) in left.enumerated() {
                let pieces = Self.showing(one, on: screen, at: part)
                for other in left.dropFirst(index + 1) {
                    for piece in Self.showing(other, on: screen, at: part) {
                        both += pieces.reduce(CGFloat(0)) { $0 + Self.area($1.intersection(piece)) }
                    }
                }
            }
            if both >= 1 { mixed += 1 }
            most = max(most, both)
            _ = harness.root.advanceFrame(Self.dt)
            tick += 1
        }
        try #require(!Self.inFlight(screen), "SETUP: a pane still moves \(tick) frames after the frame that showed the close of \(second.pane)")
        try #require(under > 0, "SETUP: in no frame after the second close is the place of another pane under a pane that grows")
        let said = left.compactMap { host -> String? in
            guard let jump = jumps[ObjectIdentifier(host)], jump > 0.5 else { return nil }
            return "\(host.pane) \((jump * 10).rounded() / 10) pt"
        }
        print("ROW (2 CLOSES): \(speed), the close of \(second.pane) in the first close's move: in the frame before, each pane that the move",
              "keeps under and that had its own move is this far from its place: \(said); panes that grow: \(grows.count); frames read: \(tick);",
              "frames with such a pane not at its place: \(away.count); frames in which a pane that left shows inside another pane that left:",
              "\(mixed), the most \(Int(most)) pt2")
        #expect(away.isEmpty, "in \(away.count) reads from the frame that shows the second close, a pane that the move keeps under is not at its place; the first: \(away.prefix(3))")
        #expect(faults.isEmpty, "\(faults.count) reads after the close of \(second.pane) in the first close's move show another pane inside a pane that grows; the first: \(faults.prefix(3))")
    }

    /// What a read of opacities over the frames of 2 acts keeps: each animation of `opacity` that a layer had, with
    /// the frame in which the layer first had it and the opacity that the layer showed before; for each layer, the
    /// opacity of its last read. `unstable`: a layer gave 2 objects for one animation, so the frames of an
    /// animation can not be counted.
    struct Lights {
        var born: [ObjectIdentifier: (animation: CAAnimation, tick: Int, was: CGFloat)] = [:]
        var shown: [ObjectIdentifier: CGFloat] = [:]
        var unstable = false
    }

    /// The opacity that `layer` shows in the frame `tick`, over 2 acts: its own value and each animation of
    /// `opacity` on it, each with its own clock, which starts in the frame in which the layer first has it. A spring
    /// is at the way of the act in whose frame it came (`scene`); a fade is at its own time. A fade that names no
    /// start goes from what the layer showed in the frame before it came.
    static func opacity(of layer: CALayer, tick: Int, scene: (Int) -> String, speed: MotionSpeed, in state: inout Lights) -> CGFloat {
        let id = ObjectIdentifier(layer)
        var value = CGFloat(layer.opacity)
        for key in (layer.animationKeys() ?? []).sorted() {
            guard let animation = layer.animation(forKey: key) as? CABasicAnimation, animation.keyPath == "opacity" else { continue }
            if layer.animation(forKey: key) !== animation { state.unstable = true }
            let from = (animation.fromValue as? NSNumber).map { CGFloat($0.doubleValue) }
            let to = (animation.toValue as? NSNumber).map { CGFloat($0.doubleValue) }
            let name = ObjectIdentifier(animation)
            let start = state.born[name] ?? (animation: animation, tick: tick, was: state.shown[id] ?? CGFloat(layer.opacity))
            state.born[name] = start
            let age = tick - start.tick
            let part = animation is CASpringAnimation ? way(of: scene(start.tick), at: speed, tick: age) : eased(animation, after: Double(age) * dt)
            if animation.isAdditive {
                let first = from ?? 0, last = to ?? 0
                value += first + (last - first) * part
            } else {
                let first = from ?? start.was, last = to ?? CGFloat(layer.opacity)
                value = first + (last - first) * part
            }
        }
        value = min(max(value, 0), 1)
        state.shown[id] = value
        return value
    }

    /// With a veil of 0.3 over each pane that has not the focus, in a glass window: a zoom and then the unzoom 3
    /// frames later, and an unzoom and then the zoom of the same pane. In each frame, from the one that shows the
    /// first act to the rest after the second, no other pane is brighter than a pane with a veil is at rest, by more
    /// than 0.05 of the light: the bound of the known limit of an unzoom's veils
    /// (``eachOtherPanesLightGoesOneWayInAMove(_:)``). The row prints the brightest light that it read.
    @Test(arguments: glassMoves)
    func theKeyAgainInAMoveMakesNoOtherPaneBrighterThanAtRest(_ look: Look) throws {
        let amount: CGFloat = 0.3, rest = 1 - amount
        var state = Lights()
        let over = try Self.overPicture(look.scene, panes: 6, gap: look.gap, speed: look.speed, configure: { model in
            model.followsDesignMetrics = false
            model.baseStyle.unfocusedPaneDim = UnfocusedPaneDim(amount: amount)
        }, before: { harness in
            guard let screen = harness.screen else { return }
            if let dim = Dim.dim(harness)?.layer { state.shown[ObjectIdentifier(dim)] = CGFloat(dim.opacity) }
            for host in Self.paneHosts(screen) {
                if let chrome = host.chrome.layer { state.shown[ObjectIdentifier(chrome)] = CGFloat(chrome.opacity) }
                if let veil = Self.veilLayer(of: host) { state.shown[ObjectIdentifier(veil)] = CGFloat(veil.opacity) }
            }
        })
        defer { over.harness.window.closeAfterTest() }
        try Self.requireKind(look.kind, of: over)
        let screen = over.screen, harness = over.harness, motion = screen.zoomDim.motion
        let mover = try #require(Self.movers(of: look.scene, on: screen).first, "SETUP: the \(look.scene) puts no pane over another")
        let others = Self.paneHosts(screen).filter { $0 !== mover }
        let first = motion.serial, second = look.scene == "zoom" ? "unzoom" : "zoom"
        var secondAt = Int.max, tick = 0, most: CGFloat = 0, strongest: CGFloat = 0
        var faults: [String] = [], series: [CGFloat] = []
        func read() {
            let at = secondAt
            let scene: (Int) -> String = { $0 < at ? look.scene : second }
            let dim = Dim.dim(harness).map { Self.opacity(of: $0.layer, tick: tick, scene: scene, speed: look.speed, in: &state) } ?? 0
            var brightest: CGFloat = 0
            for host in others where !host.isHidden {
                var veil: CGFloat = 0
                if !host.chrome.isHidden, host.chrome.alphaValue > 0, let chrome = host.chrome.layer, let layer = Self.veilLayer(of: host) {
                    let overlay = Self.opacity(of: chrome, tick: tick, scene: scene, speed: look.speed, in: &state)
                    veil = overlay * Self.opacity(of: layer, tick: tick, scene: scene, speed: look.speed, in: &state)
                }
                strongest = max(strongest, veil)
                let light = (1 - veil) * (1 - dim)
                brightest = max(brightest, light)
                if light > rest + 0.05 { faults.append("tick \(tick), \(host.pane): \((light * 100).rounded() / 100)") }
            }
            most = max(most, brightest)
            series.append((brightest * 100).rounded() / 100)
        }
        read()
        for _ in 0..<Self.framesBeforeTheKey {
            _ = harness.root.advanceFrame(Self.dt)
            tick += 1
            read()
        }
        try #require(Self.inFlight(screen), "SETUP: no pane moves \(Self.framesBeforeTheKey) frames after the frame that showed the \(look.scene)")
        try Self.secondAct(on: over, zoomed: second == "zoom" ? mover.pane : nil, of: 6, closing: mover)
        tick += 1
        secondAt = tick
        try #require(motion.serial == first + 1, "SETUP: the \(second) in the move of the \(look.scene) shows in one frame: no second act moves")
        var frames = 0
        while frames < 2 * Commit.frames {
            read()
            guard Self.inFlight(screen) else { break }
            _ = harness.root.advanceFrame(Self.dt)
            tick += 1
            frames += 1
        }
        try #require(!Self.inFlight(screen), "SETUP: a pane still moves \(frames) frames after the frame that showed the \(second)")
        try #require(!state.unstable, "SETUP: a layer gives 2 objects for one animation: the frames of an animation can not be counted")
        // An unzoom's veils come back on their ramps, and the zoom in its move takes them away again: they stay low.
        let least: CGFloat = look.scene == "zoom" ? 0.2 : 0.05
        try #require(strongest > least, "SETUP: no other pane has a veil above \(least) in the 2 acts: the strongest is \(strongest)")
        print("LIGHT ROW: \(look.testDescription), then the \(second): the brightest other pane has the light \((most * 100).rounded() / 100);",
              "a pane with a veil has \(rest) at rest; the brightest in each frame: \(series)")
        #expect(faults.isEmpty, "\(faults.count) reads show another pane brighter than at rest by more than 0.05; the first: \(faults.prefix(3))")
    }
}
