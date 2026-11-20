import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTestSupport
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, a second act in a move with no ground that gives a pane with a window a move of its own,
/// and the light of the other panes over 2 acts.
///
/// The pane that grows is opaque and whole in each frame; only the other panes dim. A window of an act before is made
/// for the place that its pane had then. A second act that moves that pane, or that takes it back, takes the window
/// off its layer (`PaneCommitMotion+Cover`): the pane is not cut at a place that is not its own.
extension PaneCommitMotionTests {
    /// The keys of the window that the act `act` put on the layer of `host`.
    static func windowKeys(on host: PaneHostView, of act: Int) -> [String] {
        let keys = ["position", "bounds.origin", "bounds.size"].map { "pane.commit.\(act).\($0)" }
        return commitKeys(on: host).filter { keys.contains($0) }
    }

    /// What is wrong with `host`, a pane that had the window `had` of an act before and has a move of its own now:
    /// it does not show, it or its clip has a mask, its layer still has an animation of that window, or the motion
    /// keeps a window for it.
    static func stillCut(_ host: PaneHostView, had: [String], by motion: PaneCommitMotion) -> [String] {
        var wrong: [String] = []
        if host.isHidden || host.layer?.isHidden ?? true { wrong.append("it does not show") }
        if host.layer?.mask != nil || host.clipView.layer?.mask != nil { wrong.append("it has a mask") }
        let old = commitKeys(on: host).filter { had.contains($0) }
        if !old.isEmpty { wrong.append("its layer has the window of the act before: \(old)") }
        if motion.covers[ObjectIdentifier(host)] != nil { wrong.append("the motion keeps a window for it") }
        return wrong
    }

    /// An unzoom in a glass window, and in its move the close of another pane. The pane that takes the room of the
    /// closed one was under the pane that the unzoom closes, and has that act's window on its layer. From the frame
    /// that shows the close it has a move of its own: it shows with no mask, its layer has no animation of the
    /// unzoom's window, and the motion keeps no window for it. So it is not cut at a place that is not its own; and
    /// it shows under the pane that the unzoom still closes, to the motion's end (a known limit). At the motion's
    /// end no pane host has an animation of the motion.
    @Test(arguments: movingSpeeds)
    func aPaneThatGetsItsOwnMoveInAnUnzoomsMoveKeepsNoWindow(_ speed: MotionSpeed) throws {
        let over = try Self.overPicture("unzoom", panes: 6, gap: "glass", speed: speed)
        defer { over.harness.window.closeAfterTest() }
        try Self.requireKind("glass", of: over)
        let screen = over.screen, harness = over.harness, motion = screen.zoomDim.motion
        let mover = try #require(Self.movers(of: "unzoom", on: screen).first, "SETUP: the unzoom puts no pane over another")
        for _ in 0..<Self.framesBeforeTheKey { _ = harness.root.advanceFrame(Self.dt) }
        try #require(Self.inFlight(screen), "SETUP: no pane moves \(Self.framesBeforeTheKey) frames after the frame that showed the unzoom")
        let first = motion.serial, gone = PaneID("pbab")
        try #require(mover.pane != gone, "SETUP: the pane that the unzoom closes is the pane of the second act")
        var had: [ObjectIdentifier: [String]] = [:]
        for host in Self.paneHosts(screen) where host !== mover && !host.isHidden && motion.covers[ObjectIdentifier(host)] != nil {
            had[ObjectIdentifier(host)] = Self.windowKeys(on: host, of: first)
        }

        _ = try #require(harness.model.showPaneClose(gone), "SETUP: the model does not show the close of \(gone)")
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        try #require(motion.serial == first + 1, "SETUP: the close in the unzoom's move shows in one frame: no second act moves")
        let own = Self.paneHosts(screen).filter { host in
            host !== mover && !host.isLeaving && !(had[ObjectIdentifier(host)] ?? []).isEmpty
                && Self.commitKeys(on: host).contains { $0.hasPrefix("pane.commit.\(first + 1).") }
        }
        try #require(!own.isEmpty, "SETUP: the close moves no pane that had a window of the unzoom")
        var faults: [String] = [], tick = 0
        while tick < 2 * Commit.frames {
            for host in own {
                let wrong = Self.stillCut(host, had: had[ObjectIdentifier(host)] ?? [], by: motion)
                if !wrong.isEmpty { faults.append("tick \(tick), \(host.pane): \(wrong.joined(separator: "; "))") }
            }
            guard Self.inFlight(screen) else { break }
            _ = harness.root.advanceFrame(Self.dt)
            tick += 1
        }
        try #require(!Self.inFlight(screen), "SETUP: a pane still moves \(tick) frames after the frame that showed the close")
        #expect(faults.isEmpty, "\(faults.count) reads of a pane with its own move in the unzoom's move are wrong; the first: \(faults.prefix(3))")
        let left = Self.leftovers(on: screen, origins: [:])
        #expect(left.isEmpty && motion.covers.isEmpty, "at the motion's end a pane host is not at rest: \(left.prefix(3)); windows that the motion keeps: \(motion.covers.count)")
    }

    /// A close in a glass window, and in its move the close is taken back. The pane that left was kept under the
    /// panes that took its room, and has the close's window on its layer: a window that ends with nothing of the
    /// pane in sight. From the frame that shows the pane again it shows with no mask, its layer has no animation of
    /// that window, and the motion keeps no window for it. At the motion's end no pane host has an animation of the
    /// motion.
    @Test(arguments: movingSpeeds)
    func aCloseTakenBackInItsMoveLeavesNoWindowOnItsPane(_ speed: MotionSpeed) throws {
        let over = try Self.overPicture("close", panes: 6, gap: "glass", speed: speed)
        defer { over.harness.window.closeAfterTest() }
        try Self.requireKind("glass", of: over)
        let screen = over.screen, harness = over.harness, motion = screen.zoomDim.motion
        let gone = try #require(Self.paneHosts(screen).first { $0.isLeaving }, "SETUP: the close keeps no pane under the others")
        for _ in 0..<Self.framesBeforeTheKey { _ = harness.root.advanceFrame(Self.dt) }
        try #require(Self.inFlight(screen), "SETUP: no pane moves \(Self.framesBeforeTheKey) frames after the frame that showed the close")
        let first = motion.serial, pane = gone.pane
        try #require(motion.covers[ObjectIdentifier(gone)] != nil, "SETUP: the pane that leaves has no window in the close's move")
        let had = Self.windowKeys(on: gone, of: first)
        try #require(!had.isEmpty, "SETUP: the pane that leaves has a window and no animation of it on its layer")

        try #require(harness.model.withdrawPaneClose(pane), "SETUP: the model has no close of \(pane) to take back")
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        try #require(motion.serial == first + 1, "SETUP: the close taken back shows in one frame: no second act moves")
        let found = Self.paneHosts(screen).first { $0.pane == pane && !$0.isLeaving && !$0.isHidden }
        let back = try #require(found, "SETUP: the screen does not show \(pane) again")
        var faults: [String] = [], tick = 0
        while tick < 2 * Commit.frames {
            let wrong = Self.stillCut(back, had: had, by: motion)
            if !wrong.isEmpty { faults.append("tick \(tick), \(pane): \(wrong.joined(separator: "; "))") }
            guard Self.inFlight(screen) else { break }
            _ = harness.root.advanceFrame(Self.dt)
            tick += 1
        }
        try #require(!Self.inFlight(screen), "SETUP: a pane still moves \(tick) frames after the frame that showed \(pane) again")
        #expect(faults.isEmpty, "\(faults.count) reads of the pane that comes back are wrong; the first: \(faults.prefix(3))")
        let left = Self.leftovers(on: screen, origins: [:])
        #expect(left.isEmpty && motion.covers.isEmpty, "at the motion's end a pane host is not at rest: \(left.prefix(3)); windows that the motion keeps: \(motion.covers.count)")
    }

    /// The 5 panes of the 6 that an unzoom of the last one does not close: the zoom in that unzoom's move is of one of them.
    nonisolated static let othersOfSix = ["p", "paab", "pab", "pb", "pbab"]

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

    /// An unzoom in a glass window, and in its move the zoom of another pane (`name`). In each frame from the one that
    /// shows that zoom, no part of another pane that shows is inside the rect of the pane that grows now, and the
    /// pane that the unzoom closed is at its place at rest: its own move ends in the pass that shows the zoom, so the
    /// zoom's window is on a pane at rest. The eye gets that pane at its place in one frame. The row prints how far
    /// the pane was from its place in the frame before, and how much of it shows past the edge of the pane that grows
    /// in the frame of the jump. A layer's animations are read each at its own part of its act.
    @Test(arguments: movingSpeeds, othersOfSix)
    func aZoomOfAnotherPaneInAnUnzoomsMoveShowsNoOtherPaneInsideIt(_ speed: MotionSpeed, _ name: String) throws {
        let over = try Self.overPicture("unzoom", panes: 6, gap: "glass", speed: speed)
        defer { over.harness.window.closeAfterTest() }
        try Self.requireKind("glass", of: over)
        let screen = over.screen, harness = over.harness, motion = screen.zoomDim.motion
        let mover = try #require(Self.movers(of: "unzoom", on: screen).first, "SETUP: the unzoom puts no pane over another")
        for _ in 0..<Self.framesBeforeTheKey { _ = harness.root.advanceFrame(Self.dt) }
        try #require(Self.inFlight(screen), "SETUP: no pane moves \(Self.framesBeforeTheKey) frames after the frame that showed the unzoom")
        let first = motion.serial
        let found = Self.paneHosts(screen).first { host in host !== mover && !host.isHidden && host.pane == PaneID(name) }
        let next = try #require(found, "SETUP: the screen shows no other pane `\(name)` in the unzoom's move")
        let jump = Self.awayFromRest(mover, on: screen, at: { _ in Self.way(of: "unzoom", at: speed, tick: Self.framesBeforeTheKey) })
        try #require(jump > 0.5, "SETUP: the pane that the unzoom closes is at its place \(Self.framesBeforeTheKey) frames into its move")

        harness.model.focus(next.pane, notify: false)
        try Self.secondAct(on: over, zoomed: next.pane, of: 6, closing: nil)
        try #require(motion.serial == first + 1, "SETUP: the zoom of \(next.pane) in the unzoom's move shows in one frame: no second act moves")
        try #require(!Self.hasFullGround(next), "SETUP: the pane that grows has a ground in a glass window")
        let others = Self.paneHosts(screen).filter { $0 !== next }
        var faults: [String] = [], under = 0, tick = 0, away: [String] = [], past: CGFloat = 0
        while Self.inFlight(screen), tick < 2 * Commit.frames {
            let now = tick
            let part: (Int) -> CGFloat = { act in
                act == first
                    ? Self.way(of: "unzoom", at: speed, tick: Self.framesBeforeTheKey + 1 + now)
                    : Self.way(of: "zoom", at: speed, tick: now)
            }
            if let layer = next.layer {
                let rect = Self.rect(of: layer, at: part)
                var shows: [String] = []
                for other in others {
                    if !other.isHidden, Self.area(other.frame.intersection(rect)) >= 1 { under += 1 }
                    let shown = Self.showing(other, on: screen, at: part)
                    let inside = shown.reduce(CGFloat(0)) { $0 + Self.area($1.intersection(rect)) }
                    if inside >= 1 { shows.append("\(other.pane) in \(Int(inside)) pt2") }
                    if other === mover, tick == 0 { past = shown.reduce(CGFloat(0)) { $0 + Self.area($1) } - inside }
                }
                if !shows.isEmpty { faults.append("tick \(tick), inside \(next.pane) at \(rect): \(shows.joined(separator: ", "))") }
            }
            let far = mover.isHidden ? 0 : Self.awayFromRest(mover, on: screen, at: part)
            if far > 0.5 { away.append("tick \(tick): \((far * 10).rounded() / 10) pt") }
            _ = harness.root.advanceFrame(Self.dt)
            tick += 1
        }
        try #require(!Self.inFlight(screen), "SETUP: a pane still moves \(tick) frames after the frame that showed the zoom of \(next.pane)")
        try #require(under > 0, "SETUP: in no frame after the zoom is the place of another pane under the pane that grows")
        print("ROW (A): \(speed), the zoom of \(next.pane) in the unzoom of \(mover.pane): in the frame before, \(mover.pane) is",
              "\((jump * 10).rounded() / 10) pt from its place; in the frame of the jump it shows \(Int(past)) pt2 past the edge of the pane",
              "that grows; its place has \(Int(Self.area(mover.frame))) pt2; frames read: \(tick); frames with \(mover.pane) not at its place: \(away.count)")
        #expect(away.isEmpty, "in \(away.count) frames from the one that shows the zoom of \(next.pane), \(mover.pane) is not at its place; the first: \(away.prefix(3))")
        #expect(faults.isEmpty, "\(faults.count) reads after the zoom of \(next.pane) in the unzoom's move show another pane inside it; the first: \(faults.prefix(3))")
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
