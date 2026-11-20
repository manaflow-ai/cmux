import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTestSupport
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, the light of the other panes in a move.
///
/// A pane that has not the focus can have a veil over it (the setting `unfocused-split-opacity`), and a zoom puts a
/// dim over each pane but the one that grows. What the screen shows of another pane is the product of the two: the
/// part of its light that the veil lets through, times the part that the dim lets through. In a move that light
/// goes one way. A zoom makes no other pane brighter in a frame than it was in the frame before, an unzoom makes
/// none darker, and in a close no pane gets brighter and then darker, or darker and then brighter.
extension PaneCommitMotionTests {
    /// How far `animation` is `time` seconds after its start: the part of its time that is spent, through its
    /// timing curve. With no curve of its own the part is the time's.
    static func eased(_ animation: CABasicAnimation, after time: Double) -> CGFloat {
        let spent = animation.duration > 0 ? min(max(time / animation.duration, 0), 1) : 1
        guard let curve = animation.timingFunction else { return CGFloat(spent) }
        var one: [Float] = [0, 0], two: [Float] = [0, 0]
        curve.getControlPoint(at: 1, values: &one)
        curve.getControlPoint(at: 2, values: &two)
        func point(_ first: Float, _ second: Float, _ at: Double) -> Double {
            3 * (1 - at) * (1 - at) * at * Double(first) + 3 * (1 - at) * at * at * Double(second) + at * at * at
        }
        var low = 0.0, high = 1.0
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if point(one[0], two[0], middle) < spent { low = middle } else { high = middle }
        }
        return CGFloat(point(one[1], two[1], (low + high) / 2))
    }

    /// The opacity that `layer` shows `time` seconds after the frame that showed an act, with the act's spring at
    /// `way`: its own value and each animation of `opacity` on it. A spring is at `way`; a fade is at its own time.
    /// An animation that adds to the value adds; another one goes from its start to its end. `was`: the value that
    /// the layer showed before the act, the start of a fade that names none.
    static func opacity(of layer: CALayer, was: Float?, after time: Double, way: CGFloat) -> CGFloat {
        var value = CGFloat(layer.opacity)
        for key in layer.animationKeys() ?? [] {
            guard let animation = layer.animation(forKey: key) as? CABasicAnimation, animation.keyPath == "opacity" else { continue }
            let part = animation is CASpringAnimation ? way : eased(animation, after: time)
            let from = (animation.fromValue as? NSNumber).map { CGFloat($0.doubleValue) }
            let to = (animation.toValue as? NSNumber).map { CGFloat($0.doubleValue) }
            if animation.isAdditive {
                let start = from ?? 0, end = to ?? 0
                value += start + (end - start) * part
            } else {
                let start = from ?? CGFloat(was ?? layer.opacity), end = to ?? CGFloat(layer.opacity)
                value = start + (end - start) * part
            }
        }
        return min(max(value, 0), 1)
    }

    /// The layer of the veil of `host`: the lowest layer of the pane's overlay.
    static func veilLayer(of host: PaneHostView) -> CALayer? { host.chrome.layer?.sublayers?.first }

    /// The strength of the veil that `host` shows: 0 with its overlay hidden; else the opacity of the overlay's
    /// layer times the opacity of the veil's layer (``opacity(of:was:after:way:)``).
    static func veil(of host: PaneHostView, was: [ObjectIdentifier: Float], after time: Double, way: CGFloat) -> CGFloat {
        guard !host.chrome.isHidden, host.chrome.alphaValue > 0, let chrome = host.chrome.layer, let veil = veilLayer(of: host) else { return 0 }
        return opacity(of: chrome, was: was[ObjectIdentifier(chrome)], after: time, way: way)
            * opacity(of: veil, was: was[ObjectIdentifier(veil)], after: time, way: way)
    }

    /// With a veil of 0.3 over each pane that has not the focus: the light of each other pane (the part that its
    /// veil lets through, times the part that the dim lets through) goes one way from the layout before the act to
    /// the rest after it. The frames: the rest before the act, the frame that shows it, each frame of the move, the
    /// rest. In a zoom no frame is brighter than the one before; in an unzoom, from the frame that shows it, none is
    /// darker; in a close no pane's light goes up in one frame and down in another. The other panes: each pane but
    /// the one that a zoom makes grow, that an unzoom closes, or that a close takes out.
    @Test(arguments: looks)
    func eachOtherPanesLightGoesOneWayInAMove(_ look: Look) throws {
        var was: [ObjectIdentifier: Float] = [:], lights: [PaneID: [CGFloat]] = [:], strongest: CGFloat = 0
        let over = try Self.overPicture(look.scene, panes: 6, gap: look.gap, speed: look.speed, configure: { model in
            model.followsDesignMetrics = false
            model.baseStyle.unfocusedPaneDim = UnfocusedPaneDim(amount: 0.3)
        }, before: { harness in
            guard let screen = harness.screen else { return }
            let dim = Dim.dim(harness)?.layer
            if let dim { was[ObjectIdentifier(dim)] = dim.opacity }
            for host in Self.paneHosts(screen) {
                if let chrome = host.chrome.layer { was[ObjectIdentifier(chrome)] = chrome.opacity }
                if let veil = Self.veilLayer(of: host) { was[ObjectIdentifier(veil)] = veil.opacity }
                guard look.scene != "unzoom", !host.isHidden else { continue }
                let veil = Self.veil(of: host, was: [:], after: 0, way: 1)
                strongest = max(strongest, veil)
                lights[host.pane] = [(1 - veil) * (1 - CGFloat(dim?.opacity ?? 0))]
            }
        })
        defer { over.harness.window.closeAfterTest() }
        try Self.requireKind(look.kind, of: over)
        let screen = over.screen, harness = over.harness
        let out = look.scene == "close" ? Self.paneHosts(screen).filter { $0.isLeaving } : Self.movers(of: look.scene, on: screen)
        try #require(!out.isEmpty, "SETUP: the \(look.scene) has no pane that grows, closes or leaves")
        let others = Self.paneHosts(screen).filter { host in !host.isHidden && !out.contains { $0 === host } }
        try #require(!others.isEmpty, "SETUP: the \(look.scene) shows no other pane")
        for host in others {
            let veil = try #require(Self.veilLayer(of: host), "SETUP: the overlay of \(host.pane) has no layer for a veil")
            try #require(veil.frame == host.chrome.dimFrame, "SETUP: the lowest layer of the overlay of \(host.pane) is not its veil")
        }
        try Self.eachTick(of: look, over) { _, way, time in
            let dim = Dim.dim(harness).map { Self.opacity(of: $0.layer, was: was[ObjectIdentifier($0.layer)], after: time, way: way) } ?? 0
            for host in others where !host.isHidden {
                let veil = Self.veil(of: host, was: was, after: time, way: way)
                strongest = max(strongest, veil)
                lights[host.pane, default: []].append((1 - veil) * (1 - dim))
            }
        }
        try #require(strongest > 0.2, "SETUP: no other pane has a veil in the \(look.scene): the strongest is \(strongest)")
        var faults: [String] = []
        for host in others {
            let values = lights[host.pane] ?? []
            let steps = zip(values, values.dropFirst()).map { $0.1 - $0.0 }
            let up = steps.contains { $0 > 0.004 }, down = steps.contains { $0 < -0.004 }
            let wrong = look.scene == "zoom" ? up : look.scene == "unzoom" ? down : up && down
            if wrong { faults.append("\(host.pane): \(values.map { ($0 * 100).rounded() / 100 })") }
        }
        #expect(faults.isEmpty, "the light of \(faults.count) panes does not go one way in the \(look.scene), frame by frame; the first: \(faults.prefix(2))")
    }
}
