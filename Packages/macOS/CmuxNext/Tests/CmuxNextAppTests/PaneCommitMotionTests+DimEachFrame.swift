import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTestSupport
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, the zoom key's rule in each frame: the pane that grows is opaque and whole in each
/// frame; only the other panes dim.
///
/// Two things dim a pane. A zoom and an unzoom put a dim over the screen, with a hole for the pane that moves: the
/// pane that a zoom makes grow, the pane that an unzoom closes to its place. And a pane that has not the focus can
/// have a veil over it (the setting `unfocused-split-opacity`). The row reads each frame of the move: no part of the
/// dim is on the cell of the pane that moves, and no veil dims that pane.
///
/// The row reads each layer at its own time. The cell is where the pane's layer shows in that frame, by the
/// animations on that layer; each part of the dim is where the animations on that part put it in that frame. A hole
/// that is behind the pane in a frame (an edge of it inside the cell) puts a part of the dim on the cell: the row is
/// red. A hole that is before the pane dims no part of the cell: the row does not read that.
///
/// The pane that grows can have a veil before its zoom: a zoom by the model, on a pane that has not the focus. The
/// model then gives that pane the focus, and the frame that shows the zoom shows it with no veil.
extension PaneCommitMotionTests {
    /// One move of the zoom key on p4 of the 2 by 2 grid.
    struct DimCase: CustomTestStringConvertible, Sendable {
        /// `zoom` or `unzoom`.
        let scene: String
        /// The strength of the veil over each pane that has not the focus. 0: no veil.
        let veil: CGFloat
        let speed: MotionSpeed
        /// Whether p4 has the focus before its zoom. If not, p1 has it, and the zoom comes by the model.
        let focused: Bool

        var testDescription: String {
            "\(scene), veil \(veil > 0 ? "on" : "off"), \(speed.rawValue), before the zoom \(focused ? "the pane" : "another pane") has the focus"
        }
    }

    nonisolated static let dimCases: [DimCase] = {
        var cases: [DimCase] = []
        for scene in ["zoom", "unzoom"] {
            for veil in [0.3, 0] as [CGFloat] {
                for speed in movingSpeeds {
                    for focused in [true, false] { cases.append(DimCase(scene: scene, veil: veil, speed: speed, focused: focused)) }
                }
            }
        }
        return cases
    }()

    /// How far `animation` is `time` seconds after its start. A spring: by its own mass, stiffness and damping, from
    /// rest, and at its end from its duration on. Another animation: through its timing curve.
    static func spent(of animation: CABasicAnimation, after time: Double) -> CGFloat {
        guard let spring = animation as? CASpringAnimation else { return eased(animation, after: time) }
        guard time < spring.duration else { return 1 }
        let mass = Double(spring.mass), stiffness = Double(spring.stiffness), damping = Double(spring.damping)
        let natural = (stiffness / mass).squareRoot()
        let ratio = damping / (2 * (stiffness * mass).squareRoot())
        let seconds = max(time, 0)
        if abs(ratio - 1) < 1e-6 { return CGFloat(1 - exp(-natural * seconds) * (1 + natural * seconds)) }
        if ratio < 1 {
            let own = natural * (1 - ratio * ratio).squareRoot()
            let swing = cos(own * seconds) + ratio * natural / own * sin(own * seconds)
            return CGFloat(1 - exp(-ratio * natural * seconds) * swing)
        }
        let root = (ratio * ratio - 1).squareRoot()
        let slow = -natural * (ratio - root), fast = -natural * (ratio + root)
        return CGFloat(1 - (fast * exp(slow * seconds) - slow * exp(fast * seconds)) / (fast - slow))
    }

    /// Where `layer` shows in its superlayer `time` seconds after the frame that put its moves on it: its own
    /// position and size, and each animation of them at its own time (``spent(of:after:)``). An animation that adds
    /// to the value adds; another one replaces it.
    static func rect(of layer: CALayer, after time: Double) -> CGRect {
        var values = [layer.position.x, layer.position.y, layer.bounds.width, layer.bounds.height]
        for key in layer.animationKeys() ?? [] {
            guard let animation = layer.animation(forKey: key) as? CABasicAnimation, let path = animation.keyPath,
                  path.hasPrefix("position") || path.hasPrefix("bounds") else { continue }
            let part = spent(of: animation, after: time)
            let from = numbers(animation.fromValue, of: path), to = numbers(animation.toValue, of: path)
            for index in 0..<4 {
                guard let start = from[index] ?? to[index], let end = to[index] ?? from[index] else { continue }
                values[index] = (animation.isAdditive ? values[index] : 0) + start + (end - start) * part
            }
        }
        let anchor = layer.anchorPoint
        return CGRect(x: values[0] - anchor.x * values[2], y: values[1] - anchor.y * values[3], width: values[2], height: values[3])
    }

    /// The opacity that each pane's overlay, each pane's veil and the dim have now on `screen`: where a fade that
    /// names no start begins.
    static func shownOpacities(of harness: Commit.Harness, on screen: ScreenContentView) -> [ObjectIdentifier: Float] {
        var was: [ObjectIdentifier: Float] = [:]
        if let dim = Dim.dim(harness)?.layer { was[ObjectIdentifier(dim)] = dim.opacity }
        for host in paneHosts(screen) {
            if let chrome = host.chrome.layer { was[ObjectIdentifier(chrome)] = chrome.opacity }
            if let veil = veilLayer(of: host) { was[ObjectIdentifier(veil)] = veil.opacity }
        }
        return was
    }

    /// In each frame of a zoom's move and of an unzoom's move, from the frame that shows the act to the rest: no
    /// part of the dim is on the cell of the pane that moves, the band of padding round its content too, and no veil
    /// dims that pane. With a veil over the panes that have not the focus and with none, at the 2 speeds at which a
    /// pane moves, and for a zoom of the pane that has the focus and of a pane that has it not.
    @Test(arguments: dimCases)
    func inEachFrameOfTheZoomKeysMovesNoDimAndNoVeilIsOnThePaneThatMoves(_ look: DimCase) throws {
        let harness = Commit.Harness(Zoom.screens(), focused: look.focused ? "p4" : "p1", holds: false) { model in
            model.followsDesignMetrics = false
            model.baseStyle.panePadding = 6
            model.baseStyle.unfocusedPaneDim = UnfocusedPaneDim(amount: look.veil)
        }
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        screen.zoomDim.motion.speed = look.speed
        let host = try #require(harness.root.context.hosts["p4"], "SETUP: p4 has no host")
        let layer = try #require(host.layer, "SETUP: p4's host has no layer")
        try #require(Dim.dim(harness) == nil && !Self.inFlight(screen), "SETUP: the grid does not rest with no dim")

        // The veils before the zoom: p2 never has the focus; p4 has a veil when p1 has the focus.
        let other = try #require(harness.root.context.hosts["p2"], "SETUP: p2 has no host")
        let before = (own: Self.veil(of: host, was: [:], after: 0, way: 1), other: Self.veil(of: other, was: [:], after: 0, way: 1))
        if look.veil > 0 {
            try #require(Self.veilLayer(of: host)?.frame == host.chrome.dimFrame, "SETUP: the layer with a fill in p4's overlay has not its veil's frame")
            try #require(before.other > 0.2, "SETUP: a pane that has not the focus has a veil of \(before.other) before the zoom")
            let fits = look.focused ? before.own < 0.001 : before.own > 0.2
            try #require(fits, "SETUP: p4 has a veil of \(before.own) before its zoom")
        } else {
            try #require(max(before.own, before.other) < 0.001, "SETUP: a pane shows a veil with the setting at 0")
        }

        // The zoom, by the model, and the frame that shows it. For an unzoom: the zoom comes to rest, the pane
        // gets a content that gives its last frame, and the unzoom shows in its frame.
        var was = Self.shownOpacities(of: harness, on: screen)
        var start = layer.frame
        harness.model.apply(screens: Zoom.screens(zoomedOn: "p4"))
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        try #require(harness.model.focusedPane == "p4", "SETUP: the model did not give the zoomed pane the focus")
        if look.scene == "unzoom" {
            Commit.rest(harness)
            try #require(!Self.inFlight(screen) && Dim.dim(harness) == nil, "SETUP: the zoom did not come to rest with no dim")
            let content = try #require(harness.provider.contents["p4"], "SETUP: the zoomed pane has no content")
            let area = PaneContentAreaView(frame: content.bounds), last = Picture(frame: content.bounds)
            area.autoresizingMask = [.width, .height]
            last.autoresizingMask = [.width, .height]
            area.addSubview(last)
            content.addSubview(area)
            was = Self.shownOpacities(of: harness, on: screen)
            start = layer.frame
            harness.model.apply(screens: Zoom.screens())
            harness.root.syncWithModel()
            _ = harness.root.advanceFrame(Self.dt)
        }
        try #require(Self.move(of: layer).moves, "SETUP: the pane has no move in the frame that shows the \(look.scene)")
        try #require(!Commit.near(start, layer.frame), "SETUP: the pane's place does not change in the \(look.scene)")
        let first = Self.rect(of: layer, after: 0)
        try #require(Commit.near(first, start), "SETUP: the read of the pane's layer does not start at its place before the act: \(first), \(start)")
        let parts = try #require(Dim.dim(harness)?.layer.sublayers, "SETUP: the frame that shows the \(look.scene) shows no dim")
        let moving = parts.filter { Self.move(of: $0).moves }.count
        try #require(parts.count == 4 && moving > 0, "SETUP: the dim has \(parts.count) parts, and \(moving) of them move")

        var tick = 0, frames = 0
        func read(_ frame: String) {
            let time = Double(tick) * Self.dt
            let veil = Self.veil(of: host, was: was, after: time, way: Self.way(of: look.scene, at: look.speed, tick: tick))
            #expect(veil <= 0.004, "\(frame): a veil of \(veil) dims the pane that moves in the \(look.scene)")
            guard let dim = Dim.dim(harness) else { return }
            frames += 1
            let cell = harness.root.convert(Self.rect(of: layer, after: time), from: screen).insetBy(dx: 1, dy: 1)
            for part in dim.layer.sublayers ?? [] {
                let cut = Self.rect(of: part, after: time).offsetBy(dx: dim.view.frame.minX, dy: dim.view.frame.minY).intersection(cell)
                #expect(cut.isNull || cut.width < 0.5 || cut.height < 0.5,
                        "\(frame): a part of the dim is on the cell of the pane that moves in the \(look.scene): \(cut) of the cell \(cell)")
            }
        }
        while Self.inFlight(screen), tick < Commit.frames {
            read("tick \(tick)")
            _ = harness.root.advanceFrame(Self.dt)
            tick += 1
        }
        try #require(!Self.inFlight(screen), "SETUP: a pane still moves \(tick) frames after the frame that showed the \(look.scene)")
        read("rest")
        try #require(tick > 2 && frames > 2, "SETUP: the move took \(tick) frames, and \(frames) of the frames read had a dim")
    }
}
