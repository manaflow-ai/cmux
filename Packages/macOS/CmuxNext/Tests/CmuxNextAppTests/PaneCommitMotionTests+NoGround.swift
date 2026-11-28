import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTestSupport
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, a pane that moves over other panes in a window that gives it no ground.
///
/// The pane that grows is opaque and whole in each frame; only the other panes dim. A pane's tab row and the room
/// around its content paint nothing. In an opaque window, and over one still picture, a pane that moves has a ground
/// under its content (`PaneCommitMotion+Sheet`), so no pane under it shows through it. A glass window, a blurred
/// picture, a picture with an opacity below 1 and a window with no picture give no such ground. There the other
/// panes must not show inside the rect of the pane that moves: each of them shows only outside that rect, in each
/// frame of the move. The rows read each frame of a zoom, an unzoom and a close in the 6 kinds of window, at the
/// 2 speeds at which a pane moves.
extension PaneCommitMotionTests {
    /// One move in one kind of window at one speed.
    struct Look: CustomTestStringConvertible, Sendable {
        /// A kind of ``windowKinds``.
        let kind: String
        /// `zoom`, `unzoom` or `close` (``overPicture(_:panes:gap:speed:padding:configure:before:)``).
        let scene: String
        let speed: MotionSpeed
        var testDescription: String { "\(scene), \(kind), \(speed.rawValue)" }

        /// The window's backdrop for ``overPicture(_:panes:gap:speed:padding:configure:before:)``.
        var gap: String? { kind == "still" ? nil : kind }
    }

    /// The kinds of window. `glass`: a glass window. `blur`: a blurred picture. `seeThrough`: a picture with an
    /// opacity below 1. `noPicture`: a window that is not opaque and shows no picture. `still`: one still picture.
    /// `opaque`: an opaque window. The last 2 give a pane that moves a ground.
    nonisolated static let windowKinds = ["glass", "blur", "seeThrough", "noPicture", "still", "opaque"]
    nonisolated static let looks: [Look] = windowKinds.flatMap { kind in
        ["zoom", "unzoom", "close"].flatMap { scene in movingSpeeds.map { Look(kind: kind, scene: scene, speed: $0) } }
    }

    /// Stops the test when the window of `over` is not of `kind`.
    static func requireKind(_ kind: String, of over: OverPicture) throws {
        var found = "opaque"
        if !over.harness.window.isOpaque {
            switch over.backdrop.stillPicture {
            case .still: found = "still"
            case .gap(.glass): found = "glass"
            case .gap(.blur): found = "blur"
            case .gap(.seeThrough): found = "seeThrough"
            case .gap(.noPicture): found = "noPicture"
            case .gap: found = "another backdrop that is no still picture"
            }
        }
        try #require(found == kind, "SETUP: the test's window is of the kind `\(found)`, not `\(kind)`")
    }

    /// How far a move of `scene` is on its spring, `tick` frames after the frame that shows it, at `speed`.
    static func way(of scene: String, at speed: MotionSpeed, tick: Int) -> CGFloat {
        let token: MotionSpring = scene == "zoom" ? .zoom : scene == "unzoom" ? .unzoom : .paneClose
        let spring = MotionPolicy(speed: speed, reduceMotion: false).spring(token)
        var value = SpringValue(0)
        value.target = 1
        for _ in 0..<(tick * 4) { value.step(dt / 4, parameters: spring) }
        return min(max(value.value, 0), 1)
    }

    /// Reads the move of `look` in the frame that shows it (tick 0), after each frame while a pane moves, and at
    /// rest. `read` gets the frame's name, how far the move's spring is, and the seconds since the frame that showed
    /// the act. Returns the count of frames that it stepped.
    @discardableResult
    static func eachTick(of look: Look, _ over: OverPicture, read: (_ frame: String, _ way: CGFloat, _ time: Double) -> Void) throws -> Int {
        var tick = 0
        while inFlight(over.screen), tick < Commit.frames {
            read("tick \(tick)", way(of: look.scene, at: look.speed, tick: tick), Double(tick) * dt)
            _ = over.harness.root.advanceFrame(dt)
            tick += 1
        }
        try #require(!inFlight(over.screen), "SETUP: a pane still moves \(tick) frames after the frame that showed the \(look.scene)")
        read("rest", 1, Double(tick) * dt)
        return tick
    }

    /// The panes that the move of `scene` puts over other panes, as `screen` shows them in the frame that shows the
    /// act: the pane that a zoom makes grow, the pane that an unzoom closes to its place, each pane that takes the
    /// room of a closed one.
    static func movers(of scene: String, on screen: ScreenContentView) -> [PaneHostView] {
        let order = stack(on: screen)
        if scene == "unzoom" { return order.last.map { [$0] } ?? [] }
        return order.filter { !$0.isLeaving && moves($0) }
    }

    /// Whether `host` has a ground under its content that covers its whole rect: a colour of alpha 1 on its layer, or
    /// a copy of the window's still picture.
    static func hasFullGround(_ host: PaneHostView) -> Bool {
        (host.layer?.backgroundColor?.alpha ?? 0) >= 1 || !pictures(on: host).isEmpty
    }

    /// The rects of `screen` in which `host` shows when the moves of each act are at `part(act)` of their way: its
    /// clip, where its layer's rect has it, less what a mask on the clip or on the layer takes away. None when the
    /// pane is hidden or has the opacity 0. A layer's rect, the origin of its own coordinates and its clip's rect
    /// are read with each animation that adds to them, so a clip that a move puts on a pane counts in each frame.
    static func showing(_ host: PaneHostView, on screen: ScreenContentView, at part: (Int) -> CGFloat) -> [CGRect] {
        guard !host.isHidden, host.alphaValue > 0, let layer = host.layer, layer.opacity > 0 else { return [] }
        let cell = rect(of: layer, at: part), end = move(of: layer, only: []).end
        let own = origin(of: layer, at: part), still = layer.bounds.origin
        let dx = cell.minX - end.minX - (own.x - still.x), dy = cell.minY - end.minY - (own.y - still.y)
        func onScreen(_ rect: CGRect) -> CGRect { screen.convert(rect, from: host.clipView).offsetBy(dx: dx, dy: dy) }
        var clip = onScreen(host.clipView.bounds)
        if let inner = host.clipView.layer {
            let now = rect(of: inner, at: part), rest = move(of: inner, only: []).end
            clip = CGRect(x: clip.minX + now.minX - rest.minX, y: clip.minY + now.minY - rest.minY,
                          width: clip.width + now.width - rest.width, height: clip.height + now.height - rest.height)
        }
        var parts = [clip.intersection(cell)]
        if let mask = host.clipView.layer?.mask {
            parts = shown(mask, at: part).map { onScreen($0).intersection(clip).intersection(cell) }
        }
        if let mask = layer.mask {
            let holes = shown(mask, at: part).map { $0.offsetBy(dx: cell.minX - own.x, dy: cell.minY - own.y) }
            parts = parts.flatMap { piece in holes.map { $0.intersection(piece) } }
        }
        return parts.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
    }

    /// In the frame that shows a zoom, an unzoom or a close, in each frame of the move and at rest, no part of another
    /// pane that shows is inside the rect of a pane that moves, unless that pane has a ground that covers its whole
    /// rect. The rects of a frame are the ones that the animations on the layers give at that frame's part of the
    /// act's spring. With a ground the pane covers what is under it; with none, each other pane has a clip that
    /// keeps it out of that rect. A clip can take more of a pane than the rect covers, never less.
    @Test(arguments: looks)
    func noOtherPaneShowsInsideAPaneThatMovesWithNoGround(_ look: Look) throws {
        let over = try Self.overPicture(look.scene, panes: 6, gap: look.gap, speed: look.speed)
        defer { over.harness.window.closeAfterTest() }
        try Self.requireKind(look.kind, of: over)
        let screen = over.screen
        let movers = Self.movers(of: look.scene, on: screen)
        try #require(!movers.isEmpty, "SETUP: the \(look.scene) puts no pane over another")
        let others = Self.paneHosts(screen).filter { host in !movers.contains { $0 === host } }
        var faults: [String] = [], bare = 0, covered = 0
        let frames = try Self.eachTick(of: look, over) { frame, way, _ in
            for mover in movers {
                guard let layer = mover.layer else { continue }
                let rect = Self.rect(of: layer) { _ in way }
                if others.contains(where: { !$0.isHidden && Self.area($0.frame.intersection(rect)) >= 1 }) { covered += 1 }
                guard !Self.hasFullGround(mover) else { continue }
                var shows: [String] = []
                for other in others {
                    let pieces = Self.showing(other, on: screen) { _ in way }
                    let under = pieces.reduce(CGFloat(0)) { $0 + Self.area($1.intersection(rect)) }
                    if under >= 1 { shows.append("\(other.pane) in \(Int(under)) pt2") }
                }
                if frame != "rest" { bare += 1 }
                if !shows.isEmpty { faults.append("\(frame), inside \(mover.pane) at \(rect): \(shows.joined(separator: ", "))") }
            }
        }
        try #require(covered > 0, "SETUP: in no frame of the \(look.scene) is the place of another pane under a pane that moves")
        let grounded = look.kind == "still" || look.kind == "opaque"
        try #require(grounded || bare > 0, "SETUP: each pane that moves has a ground in each of the \(frames) frames, in a window of the kind `\(look.kind)`")
        #expect(faults.isEmpty, "\(faults.count) reads show another pane inside a pane that moves with no ground; the first: \(faults.prefix(3))")
    }

    /// What of `host` is not whole now: the pane, its clip and (with `content`) its content show, each with the
    /// opacity 1, with no animation of `opacity` and with no mask.
    static func notWhole(_ host: PaneHostView, content: NSView?) -> [String] {
        var found: [String] = []
        var views: [(String, NSView)] = [("pane", host), ("clip", host.clipView)]
        if let content { views.append(("content", content)) }
        for (name, view) in views {
            guard let layer = view.layer else {
                found.append("its \(name) has no layer")
                continue
            }
            if view.isHidden || layer.isHidden { found.append("its \(name) is hidden") }
            if view.alphaValue < 1 || layer.opacity < 1 { found.append("its \(name) has an opacity below 1") }
            let fades = (layer.animationKeys() ?? []).contains { (layer.animation(forKey: $0) as? CAPropertyAnimation)?.keyPath == "opacity" }
            if fades { found.append("its \(name) has an animation of `opacity`") }
            if layer.mask != nil { found.append("its \(name) has a mask") }
        }
        return found
    }

    /// A pane that moves over other panes is whole in each frame, in each kind of window: the pane and its clip show
    /// with the opacity 1, with no animation of `opacity` and no mask. In a zoom and a close its content too; a pane
    /// that an unzoom closes shows its last frame in the place of its content (`PaneCommitMotionTests+Unzoom`). In a
    /// zoom no picture stands in for the content of the pane that grows, and its content has its final size from
    /// the frame that shows the zoom: no frame of the move lays the content out again.
    @Test(arguments: looks)
    func aPaneThatMovesOverOthersIsWholeInEachFrame(_ look: Look) throws {
        let over = try Self.overPicture(look.scene, panes: 6, gap: look.gap, speed: look.speed)
        defer { over.harness.window.closeAfterTest() }
        try Self.requireKind(look.kind, of: over)
        let screen = over.screen, harness = over.harness
        let movers = Self.movers(of: look.scene, on: screen)
        try #require(!movers.isEmpty, "SETUP: the \(look.scene) puts no pane over another")
        let first = movers.map { harness.provider.contents[$0.pane]?.frame.size }
        var faults: [String] = []
        try Self.eachTick(of: look, over) { frame, _, _ in
            for mover in movers {
                let content = look.scene == "unzoom" ? nil : harness.provider.contents[mover.pane]
                var found = Self.notWhole(mover, content: content)
                if look.scene != "unzoom", content == nil { found.append("it has no content") }
                if look.scene == "zoom", frame != "rest" {
                    if !Self.lastFrames(on: screen).isEmpty { found.append("a picture stands in for a pane's content") }
                    if mover.holdsContentForMove { found.append("its content keeps an old size for the move") }
                }
                if !found.isEmpty { faults.append("\(frame), \(mover.pane): \(found.joined(separator: "; "))") }
            }
        }
        #expect(faults.isEmpty, "\(faults.count) reads of a pane that moves over others are not whole; the first: \(faults.prefix(3))")
        guard look.scene == "zoom" else { return }
        let last = movers.map { harness.provider.contents[$0.pane]?.frame.size }
        #expect(first == last, "the content of the pane that grows has the size \(first) in the frame that shows the zoom and \(last) at rest")
    }
}
