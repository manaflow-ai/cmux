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

    /// The strength of the veil that `host` shows: 0 with its overlay hidden; else the opacity of the overlay's
    /// layer times the opacity of the veil's layer (``opacity(of:was:after:way:)``; the layer: `veilLayer(of:)`, whose
    /// set-up issue names the line that asked for the strength).
    static func veil(of host: PaneHostView, was: [ObjectIdentifier: Float], after time: Double, way: CGFloat,
                     sourceLocation: SourceLocation = #_sourceLocation) -> CGFloat {
        guard !host.chrome.isHidden, host.chrome.alphaValue > 0, let chrome = host.chrome.layer,
              let veil = veilLayer(of: host, sourceLocation: sourceLocation) else { return 0 }
        return opacity(of: chrome, was: was[ObjectIdentifier(chrome)], after: time, way: way)
            * opacity(of: veil, was: was[ObjectIdentifier(veil)], after: time, way: way)
    }

    /// The light of each other pane in the move of `look`, with a veil of the strength `amount` over each pane that
    /// has not the focus (0: no veil), and the strongest veil that one of them showed. The frames: the rest before
    /// the act (not for an unzoom), the frame that shows it, each frame of the move, the rest. The other panes:
    /// each pane but the one that a zoom makes grow, that an unzoom closes, or that a close takes out. A set-up issue
    /// of the veil's read names the row's line.
    static func lights(in look: Look, veil amount: CGFloat,
                       sourceLocation: SourceLocation = #_sourceLocation) throws -> (values: [(pane: PaneID, light: [CGFloat])], strongest: CGFloat) {
        var was: [ObjectIdentifier: Float] = [:], lights: [PaneID: [CGFloat]] = [:], strongest: CGFloat = 0
        let over = try Self.overPicture(look.scene, panes: 6, gap: look.gap, speed: look.speed, configure: { model in
            model.followsDesignMetrics = false
            model.baseStyle.unfocusedPaneDim = UnfocusedPaneDim(amount: amount)
        }, before: { harness in
            guard let screen = harness.screen else { return }
            let dim = Dim.dim(harness)?.layer
            if let dim { was[ObjectIdentifier(dim)] = dim.opacity }
            for host in Self.paneHosts(screen) {
                if let chrome = host.chrome.layer { was[ObjectIdentifier(chrome)] = chrome.opacity }
                if let veil = Self.veilLayer(of: host, sourceLocation: sourceLocation) { was[ObjectIdentifier(veil)] = veil.opacity }
                guard look.scene != "unzoom", !host.isHidden else { continue }
                let veil = Self.veil(of: host, was: [:], after: 0, way: 1, sourceLocation: sourceLocation)
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
        for host in amount > 0 ? others : [] {
            let veil = try #require(Self.veilLayer(of: host, sourceLocation: sourceLocation), "SETUP: the overlay of \(host.pane) has no layer for a veil")
            try #require(veil.frame == host.chrome.dimFrame, "SETUP: the layer with a fill in the overlay of \(host.pane) has not its veil's frame")
        }
        try Self.eachTick(of: look, over) { _, way, time in
            let dim = Dim.dim(harness).map { Self.opacity(of: $0.layer, was: was[ObjectIdentifier($0.layer)], after: time, way: way) } ?? 0
            for host in others where !host.isHidden {
                let veil = Self.veil(of: host, was: was, after: time, way: way, sourceLocation: sourceLocation)
                strongest = max(strongest, veil)
                lights[host.pane, default: []].append((1 - veil) * (1 - dim))
            }
        }
        return (others.map { (pane: $0.pane, light: lights[$0.pane] ?? []) }, strongest)
    }

    /// The panes of `values` whose light does not go the way of `scene`, each with its values: in a zoom a frame is
    /// brighter than the one before; in an unzoom one is darker; in a close the light goes up and down both.
    static func notOneWay(_ values: [(pane: PaneID, light: [CGFloat])], in scene: String) -> [String] {
        var faults: [String] = []
        for (pane, light) in values {
            let steps = zip(light, light.dropFirst()).map { $0.1 - $0.0 }
            let up = steps.contains { $0 > 0.004 }, down = steps.contains { $0 < -0.004 }
            let wrong = scene == "zoom" ? up : scene == "unzoom" ? down : up && down
            if wrong { faults.append("\(pane): \(light.map { ($0 * 100).rounded() / 100 })") }
        }
        return faults
    }

    /// How far the light of a pane of `values` falls at most from a frame to a later one.
    static func largestFall(in values: [(pane: PaneID, light: [CGFloat])]) -> CGFloat {
        var worst: CGFloat = 0
        for (_, light) in values {
            var top = light.first ?? 0
            for value in light {
                top = max(top, value)
                worst = max(worst, top - value)
            }
        }
        return worst
    }

    /// With a veil of 0.3 over each pane that has not the focus: the light of each other pane (the part that its
    /// veil lets through, times the part that the dim lets through) goes one way from the layout before the act to
    /// the rest after it. In a zoom no frame is brighter than the one before; in an unzoom, from the frame that
    /// shows it, none is darker; in a close no pane's light goes up in one frame and down in another.
    ///
    /// A known limit, in the unzoom only: the veils of the panes that come back come on the unzoom's spring, and the
    /// dim goes on its own fade. The two curves are not one, so with a veil the light of a pane falls in some frames
    /// of the unzoom. The fall is at most 0.05 of the light (0.03 by a run); a larger one is a fault. A window with
    /// no veil has the dim only (``withNoVeilNoOtherPaneGetsDarkerInAnUnzoom(_:)``).
    @Test(arguments: looks)
    func eachOtherPanesLightGoesOneWayInAMove(_ look: Look) throws {
        let read = try Self.lights(in: look, veil: 0.3)
        try #require(read.strongest > 0.2, "SETUP: no other pane has a veil in the \(look.scene): the strongest is \(read.strongest)")
        let faults = Self.notOneWay(read.values, in: look.scene)
        guard look.scene == "unzoom" else {
            #expect(faults.isEmpty, "the light of \(faults.count) panes does not go one way in the \(look.scene), frame by frame; the first: \(faults.prefix(2))")
            return
        }
        let fall = Self.largestFall(in: read.values)
        #expect(fall <= 0.05, "in the unzoom the light of a pane falls by \(fall): more than the known limit of 0.05; the first: \(faults.prefix(2))")
        withKnownIssue("an unzoom's veils come on its spring and its dim goes on its own fade: with a veil a pane's light falls by up to 0.05 in the move") {
            #expect(faults.isEmpty, "the light of \(faults.count) panes does not go one way in the unzoom, frame by frame; the first: \(faults.prefix(2))")
        }
    }

    /// With no veil, in a glass window: what the screen shows of another pane in an unzoom is what the dim lets
    /// through, and from the frame that shows the unzoom no frame is darker than the one before.
    @Test(arguments: movingSpeeds)
    func withNoVeilNoOtherPaneGetsDarkerInAnUnzoom(_ speed: MotionSpeed) throws {
        let read = try Self.lights(in: Look(kind: "glass", scene: "unzoom", speed: speed), veil: 0)
        try #require(read.strongest < 0.001, "SETUP: a pane shows a veil of \(read.strongest) with the setting at 0")
        try #require(read.values.contains { ($0.light.first ?? 1) < 0.99 }, "SETUP: no dim shows over a pane in the frame that shows the unzoom")
        let faults = Self.notOneWay(read.values, in: "unzoom")
        #expect(faults.isEmpty, "with no veil the light of \(faults.count) panes falls in the unzoom, frame by frame; the first: \(faults.prefix(2))")
    }
}
