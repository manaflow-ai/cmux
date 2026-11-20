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

    /// An unzoom in a glass window, and in its move the zoom of another pane. In each frame from the one that shows
    /// that zoom, no part of another pane that shows is inside the rect of the pane that grows now. The pane that the
    /// unzoom closes still has its own move, and the zoom's window is on its layer too: the 2 are read each at its
    /// own part of its act.
    @Test(arguments: movingSpeeds)
    func aZoomOfAnotherPaneInAnUnzoomsMoveShowsNoOtherPaneInsideIt(_ speed: MotionSpeed) throws {
        let over = try Self.overPicture("unzoom", panes: 6, gap: "glass", speed: speed)
        defer { over.harness.window.closeAfterTest() }
        try Self.requireKind("glass", of: over)
        let screen = over.screen, harness = over.harness, motion = screen.zoomDim.motion
        let mover = try #require(Self.movers(of: "unzoom", on: screen).first, "SETUP: the unzoom puts no pane over another")
        for _ in 0..<Self.framesBeforeTheKey { _ = harness.root.advanceFrame(Self.dt) }
        try #require(Self.inFlight(screen), "SETUP: no pane moves \(Self.framesBeforeTheKey) frames after the frame that showed the unzoom")
        let first = motion.serial
        let found = Self.paneHosts(screen).first { host in host !== mover && !host.isHidden && motion.covers[ObjectIdentifier(host)] != nil }
        let next = try #require(found, "SETUP: no other pane has a window in the unzoom's move")

        harness.model.focus(next.pane, notify: false)
        try Self.secondAct(on: over, zoomed: next.pane, of: 6, closing: nil)
        try #require(motion.serial == first + 1, "SETUP: the zoom of \(next.pane) in the unzoom's move shows in one frame: no second act moves")
        try #require(!Self.hasFullGround(next), "SETUP: the pane that grows has a ground in a glass window")
        let others = Self.paneHosts(screen).filter { $0 !== next }
        var faults: [String] = [], under = 0, tick = 0
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
                    let inside = Self.showing(other, on: screen, at: part).reduce(CGFloat(0)) { $0 + Self.area($1.intersection(rect)) }
                    if inside >= 1 { shows.append("\(other.pane) in \(Int(inside)) pt2") }
                }
                if !shows.isEmpty { faults.append("tick \(tick), inside \(next.pane) at \(rect): \(shows.joined(separator: ", "))") }
            }
            _ = harness.root.advanceFrame(Self.dt)
            tick += 1
        }
        try #require(!Self.inFlight(screen), "SETUP: a pane still moves \(tick) frames after the frame that showed the zoom of \(next.pane)")
        try #require(under > 0, "SETUP: in no frame after the zoom is the place of another pane under the pane that grows")
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
        try #require(strongest > 0.2, "SETUP: no other pane has a veil in the 2 acts: the strongest is \(strongest)")
        print("LIGHT ROW: \(look.testDescription), then the \(second): the brightest other pane has the light \((most * 100).rounded() / 100);",
              "a pane with a veil has \(rest) at rest; the brightest in each frame: \(series)")
        #expect(faults.isEmpty, "\(faults.count) reads show another pane brighter than at rest by more than 0.05; the first: \(faults.prefix(3))")
    }
}
