public import AppKit
import CmuxNextDesignTokens

/// What the goo surface is made of this frame, in the shade's coordinates (`GooMorphEngine.scene`).
public nonisolated struct GooScene: Equatable, Sendable {
    /// Cards whose outline the field leaves as is away from their droplets: the main pane's card under the band
    /// (group 0) and, in a pool look, the sidebar's card (group 1). They must not overlap.
    public var cards: [GooShape]
    /// Shapes that hang from a card (the active tab of each top-row pane, the sidebar's +), each keyed so its
    /// springs follow it from one target to the next: a tab switch moves the same droplet.
    public var droplets: [Droplet]
    /// How much the cards' groups flow into each other (the sidebar's card budding out of the pane's or drawn back
    /// into it), 0 to 1, and the gutter between them that the field must trace while it is above 0.
    public var crossBlend: CGFloat
    public var crossWindow: CGRect?
    /// The inputs move on their own this frame (a tab move in flight, a sidebar slide): the engine keeps reading.
    public var live: Bool
    /// The x the droplets ride (the main card's leading edge): their springs work relative to it, so a sidebar
    /// slide carries them with their tabs, and its speed only drags their trailing side out a little.
    public var anchorX: CGFloat = 0
    /// The main card's outline up to the tabs' top, its top corners the leftmost tab's (`GooCorner`): group 0
    /// never leaves it, and a droplet near its leading edge hangs on that edge, flush.
    public var wall: GooShape?

    public struct Droplet: Equatable, Sendable {
        public var key: Int
        public var rect: CGRect
        public var group: Int
        /// The droplet keeps this edge when it thins (the one against its card), so it never lifts off it.
        public var keepsMinY: Bool
        /// How strongly it pulls (`GooShape.weight`): a droplet clipped away melts.
        public var weight: CGFloat

        public init(key: Int, rect: CGRect, group: Int, keepsMinY: Bool, weight: CGFloat = 1) {
            self.key = key
            self.rect = rect
            self.group = group
            self.keepsMinY = keepsMinY
            self.weight = weight
        }
    }

    public init(cards: [GooShape], droplets: [Droplet], crossBlend: CGFloat = 0, crossWindow: CGRect? = nil, live: Bool = false) {
        self.cards = cards
        self.droplets = droplets
        self.crossBlend = crossBlend
        self.crossWindow = crossWindow
        self.live = live
    }
}

/// Moves and draws the goo surface (`GooMorphVariant`). Each droplet's left and right edges ride their own
/// springs: the edge on the side it travels to is fast and the one it leaves is slow, so a droplet stretches
/// toward a newly selected tab and gathers itself there, and it thins as it stretches so its area holds, as
/// liquid does. Every frame it reads the scene (where the tabs and cards show now, moves in flight included),
/// steps the springs on the window's one motion clock and traces the field once. It stops when the springs
/// settle and nothing it reads is moving; with tab motion off it lands in one frame.
@MainActor
public final class GooMorphEngine: MotionAnimating {
    /// Reads the scene now; nil when the goo look draws nothing.
    public var scene: (() -> GooScene?)?
    /// Takes the traced surface (nil: none).
    public var draw: ((CGPath?) -> Void)?
    /// The view whose window's clock steps the springs.
    public weak var host: NSView?
    public var style: GooStyle?
    private var edges: [Int: Edges] = [:]
    private var running = false
    private var lastDrawn: CGPath?
    /// The anchor's last x and its smoothed speed (points per second), for the drag.
    private var anchor: CGFloat?
    private var anchorSpeed: CGFloat = 0

    /// Trace cost, for `debug.timings` (key `goo_trace`): the loops' time off the main thread.
    public private(set) var costs = GooCosts()
    /// The trace running off the main thread, and the newest one asked for meanwhile: only the newest runs next.
    private var tracing: Task<Void, Never>?
    private var queued: GooTrace?
    /// Bumped when the look stops drawing, so a trace still in flight draws nothing.
    private var generation = 0

    public init() {}

    public func resetCosts() { costs.reset() }

    /// The inputs changed: lands at once when nothing would move (or motion is off), else runs until it settles.
    public func update() {
        guard let style, let scene = scene?() else {
            edges = [:]
            generation += 1
            queued = nil
            if lastDrawn != nil { lastDrawn = nil; draw?(nil) }
            return
        }
        let animates = Motion.tabs.animatesMovement && host?.window != nil
        retarget(scene, style: style, snap: !animates)
        if animates, scene.live || !settled(scene) {
            if !running, let host {
                running = true
                MotionClock.forView(host).run(self, trace: "goo.morph")
            }
            // The clock's step draws this frame; drawing here too would trace twice.
            if running { return }
        }
        render(scene, style: style)
    }

    public func motionStep(_ dt: Double) -> Bool {
        guard let style, let scene = scene?() else {
            running = false
            update()
            return false
        }
        retarget(scene, style: style, snap: false)
        if let anchor, dt > 0 {
            let speed = (scene.anchorX - anchor) / CGFloat(dt)
            anchorSpeed += (speed - anchorSpeed) * 0.5
        }
        anchor = scene.anchorX
        if !scene.live { anchorSpeed *= 0.6 }
        // The springs' responses are the fast speed's; the animation speed setting stretches them.
        let scaled = dt / max(0.1, Motion.tabs.speed.timeScale) / max(1, GooMorphVariant.slowMotion.value)
        // Small steps: the fast edge's spring is stiff for the frame's length.
        let steps = max(1, Int((scaled * 480).rounded(.up)))
        let h = scaled / Double(steps)
        for key in edges.keys {
            for _ in 0..<steps { edges[key]?.step(h, style: style) }
        }
        let done = !scene.live && settled(scene) && abs(anchorSpeed) < 4
        if done {
            for key in edges.keys { edges[key]?.land() }
            anchorSpeed = 0
            anchor = nil
        }
        render(scene, style: style)
        running = !done
        return running
    }

    /// New droplets start at their target; gone ones drop their springs.
    private func retarget(_ scene: GooScene, style: GooStyle, snap: Bool) {
        var seen = Set<Int>()
        for droplet in scene.droplets {
            seen.insert(droplet.key)
            let rect = droplet.rect.offsetBy(dx: -scene.anchorX, dy: 0)
            if snap || edges[droplet.key] == nil {
                edges[droplet.key] = Edges(rect)
            } else {
                edges[droplet.key]?.target = rect
            }
        }
        if snap { anchorSpeed = 0 }
        for key in edges.keys where !seen.contains(key) { edges[key] = nil }
    }

    private func settled(_ scene: GooScene) -> Bool {
        edges.values.allSatisfy(\.isSettled)
    }

    // perf-hot: 1ms goo.morph scene per frame while a tab or the sidebar moves (the trace runs off the main thread)
    private func render(_ scene: GooScene, style: GooStyle) {
        let reach = style.reach
        var shapes = scene.cards
        var windows: [CGRect] = []
        for droplet in scene.droplets {
            guard let edge = edges[droplet.key] else { continue }
            var rect = edge.shown(droplet, thinning: style.thinning).offsetBy(dx: scene.anchorX, dy: 0)
            // The leftmost tab presses on the card's edge: near it, the droplet reaches past the wall, which cuts it
            // flush; leaving, it peels off the edge as liquid does. Not while the sidebar's card flows across.
            if droplet.group == 0, let wall = scene.wall {
                let gap = rect.minX - wall.rect.minX
                let pull = (1 - Self.smoothstep(gap, from: 12, to: 52)) * (1 - scene.crossBlend)
                if pull > 0 { rect = CGRect(x: rect.minX - pull * (gap + rect.height), y: rect.minY, width: rect.width + pull * (gap + rect.height), height: rect.height) }
            }
            // Dragged by the card's motion: the trailing side lags a little, as liquid does.
            let drag = min(14, abs(anchorSpeed) * 0.016)
            if anchorSpeed > 0 { rect.origin.x -= drag }
            rect.size.width += drag
            guard rect.width > 1, rect.height > 1, droplet.weight > 0.001 else { continue }
            shapes.append(GooShape(rect: rect, radius: rect.height / 2, group: droplet.group, weight: droplet.weight))
            windows.append(rect.insetBy(dx: -(reach + 2), dy: -(reach + 2)))
        }
        if scene.crossBlend > 0, let gutter = scene.crossWindow { windows.append(gutter.insetBy(dx: -(reach + 2), dy: -(reach + 2))) }
        let field = GooField(shapes: shapes, reach: reach, crossBlend: scene.crossBlend, wall: scene.wall, wallStrength: 1 - scene.crossBlend)
        // A card the cross blend reshapes (the sidebar's, budding or melting) is traced, not drawn as is.
        let plain = scene.crossBlend > 0 ? scene.cards.filter { card in !(scene.crossWindow?.contains(card.rect) ?? false) } : scene.cards
        // A slide traces the sidebar's whole height while it melts: a coarser grid there, in motion.
        trace(GooTrace(field: field, plain: plain, windows: windows, step: scene.crossBlend > 0 ? 3 : 2))
    }

    /// Traces off the main thread and draws the result on it, one trace at a time: a frame that asks while one runs
    /// replaces the queued one, so the surface always catches up to the newest scene and the main thread never waits.
    private func trace(_ job: GooTrace) {
        guard tracing == nil else { queued = job; return }
        let generation = generation
        tracing = Task { [weak self] in
            let (loops, nanoseconds) = await Task.detached(priority: .userInitiated) {
                let start = DispatchTime.now().uptimeNanoseconds
                let loops = job.loops()
                return (loops, DispatchTime.now().uptimeNanoseconds - start)
            }.value
            guard let self else { return }
            tracing = nil
            costs.record(nanoseconds: nanoseconds)
            if generation == self.generation {
                let path = job.path(loops)
                lastDrawn = path
                draw?(path)
            }
            if let next = queued {
                queued = nil
                trace(next)
            }
        }
    }

    private static func smoothstep(_ x: CGFloat, from a: CGFloat, to b: CGFloat) -> CGFloat {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// A droplet's two edges on springs toward its target, and its height from the stretch.
private struct Edges {
    var target: CGRect
    var minX: CGFloat, maxX: CGFloat
    var vMin: CGFloat = 0, vMax: CGFloat = 0

    init(_ rect: CGRect) {
        target = rect
        minX = rect.minX
        maxX = rect.maxX
    }

    var isSettled: Bool {
        abs(minX - target.minX) < 0.05 && abs(maxX - target.maxX) < 0.05 && abs(vMin) < 1 && abs(vMax) < 1
    }

    mutating func land() {
        (minX, maxX, vMin, vMax) = (target.minX, target.maxX, 0, 0)
    }

    mutating func step(_ dt: Double, style: GooStyle) {
        // The edge on the side the droplet travels to leads; the other trails.
        let travel = (target.minX + target.maxX) - (minX + maxX)
        let leftLeads = travel < 0
        Self.spring(&minX, &vMin, to: target.minX, leftLeads ? style.lead : style.trail, dt: dt)
        Self.spring(&maxX, &vMax, to: target.maxX, leftLeads ? style.trail : style.lead, dt: dt)
        // Never inside out.
        if maxX < minX + 2 { let mid = (minX + maxX) / 2; (minX, maxX) = (mid - 1, mid + 1) }
    }

    private static func spring(_ x: inout CGFloat, _ v: inout CGFloat, to target: CGFloat, _ spring: SpringParameters, dt: Double) {
        let omega = 2 * Double.pi / max(spring.response, 0.01)
        let force = omega * omega * Double(target - x) - 2 * spring.dampingFraction * omega * Double(v)
        v += CGFloat(force * dt)
        x += v * CGFloat(dt)
    }

    /// The droplet as it shows: its edges where the springs are, thinner when stretched (area kept by `thinning`)
    /// and a little fuller when squeezed, on the edge against its card.
    func shown(_ droplet: GooScene.Droplet, thinning: CGFloat) -> CGRect {
        let width = maxX - minX, rest = max(1, target.width)
        let ratio = rest / max(width, 1)
        let factor = min(1.12, max(0.5, 1 + thinning * (ratio - 1)))
        let height = target.height * factor
        let y = droplet.keepsMinY ? target.minY : target.maxY - height
        return CGRect(x: minX, y: y, width: width, height: height)
    }
}

/// Rolling trace cost of the goo surface (`debug.timings` key `goo`).
public nonisolated struct GooCosts: Sendable {
    public private(set) var count = 0
    private var samples: [Double] = []

    mutating func record(nanoseconds: UInt64) {
        count += 1
        if samples.count >= 2048 { samples.removeFirst(samples.count - 2047) }
        samples.append(Double(nanoseconds) / 1e6)
    }

    /// Count, p50, p95, p99 and max of the recent traces, in milliseconds.
    public var summary: [String: Double] {
        guard !samples.isEmpty else { return ["count": 0] }
        let sorted = samples.sorted()
        func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))] }
        return ["count": Double(count), "p50_ms": at(0.5), "p95_ms": at(0.95), "p99_ms": at(0.99), "max_ms": sorted[sorted.count - 1]]
    }

    mutating func reset() {
        count = 0
        samples = []
    }
}
