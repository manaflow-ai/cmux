public import CoreGraphics
public import CmuxNextDesignTokens

// Thunderdome r2 C, "goo morph" (Debug `chrome.gooMorph`). Leo 2026-11-05 on round 1: "barely even tried";
// he likes the rounded corners and the inner card ("a glass frame, another glass frame"), and hates "a tangent
// line and then two other things that go to points". The top of the window is one band of chrome over the
// sidebar and every top-row tab strip; below it sit the cards, and the active tab is a droplet of its pane's
// card that hangs into the band through a liquid neck. The shapes are one metaball field, so they flow into
// each other with no straight segment, fillet or point, and they stretch when they move.

/// Which goo look the window draws (Debug Settings `chrome.gooMorph`, off by default).
public nonisolated enum GooMorphVariant: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The plain card, as before.
    case off
    /// One band of chrome across the top; the active tab is a droplet of its pane's card. The sidebar sits on
    /// the chrome.
    case drop
    /// `drop`, and the sidebar is its own card under the band with the + as its droplet: the + and the active tab
    /// are the same shape on the same row. The sidebar's card buds out of the pane's card as it opens and is
    /// drawn back into it as it closes.
    case pool
    /// `pool`, thicker and slower: a wider reach, a longer stretch and a wobble as it lands.
    case slime

    public var tunableTitle: String {
        switch self {
        case .off: "Off: plain card"
        case .drop: "Drop: the active tab is a droplet of its pane"
        case .pool: "Pool: the sidebar is a card too, its + a droplet"
        case .slime: "Slime: pool, thicker and slower"
        }
    }

    public static let tunable = Tunable<GooMorphVariant>.choice(
        "chrome.gooMorph", .sidebar, "Goo morph (Thunderdome r2 C)",
        help: "One band of chrome across the top of the window; the active tab, the sidebar's corner and the cards are one liquid shape that stretches when it moves.",
        default: .off, code: "GooMorphVariant.tunable")

    /// Debug only: the goo's own clock runs this many times slower, so a capture's few frames a second show a
    /// droplet's stretch (`chrome.gooMorph.slowMotion`, 1 by default). The tabs and the sidebar keep their speed.
    public static let slowMotion = Tunable<Double>.number(
        "chrome.gooMorph.slowMotion", .sidebar, "Goo morph slow motion",
        help: "Captures only: the goo morph's springs run this many times slower.", default: 1, range: 1...12, step: 1,
        unit: .multiplier, code: "GooMorphVariant.slowMotion")

    /// The look's parameters; nil when off.
    public var style: GooStyle? {
        switch self {
        case .off: nil
        case .drop: GooStyle(reach: 22, sidebarCard: false, lead: MotionSpring.gooLead.base, trail: MotionSpring.gooTrail.base, thinning: 0.55)
        case .pool: GooStyle(reach: 22, sidebarCard: true, lead: MotionSpring.gooLead.base, trail: MotionSpring.gooTrail.base, thinning: 0.55)
        // Thicker: the same springs, a third slower and with more give, so it wobbles as it lands.
        case .slime: GooStyle(reach: 28, sidebarCard: true, lead: MotionSpring.gooLead.base.slimed, trail: MotionSpring.gooTrail.base.slimed, thinning: 0.8)
        }
    }
}

/// How a goo look draws and moves.
public nonisolated struct GooStyle: Equatable, Sendable {
    /// How far a shape's pull reaches (points): two shapes closer than about 0.4 of it join through a neck.
    public var reach: CGFloat
    /// The sidebar is a card of its own under the band, with the + as its droplet.
    public var sidebarCard: Bool
    /// The spring of a droplet's edge on the side it travels to (fast) and the side it leaves (slow): the
    /// difference is the stretch.
    public var lead: SpringParameters
    public var trail: SpringParameters
    /// How much a stretched droplet thins to keep its area (0 none, 1 all of it).
    public var thinning: CGFloat
}

private nonisolated extension SpringParameters {
    /// Slime's version of a goo spring: slower, with more give.
    var slimed: SpringParameters { SpringParameters(response: response * 1.4, dampingFraction: dampingFraction * 0.76) }
}

/// One shape of the field: a rounded rect in a group. Shapes of one group add up (they flow into each other);
/// groups only join where `GooField.crossBlend` says.
public nonisolated struct GooShape: Equatable, Sendable {
    public var rect: CGRect
    public var radius: CGFloat
    public var group: Int
    /// How strongly it pulls, 0 to 1: below 1 it shrinks inside its rect, and at 0 it is gone, so a shape comes
    /// and goes by melting, never in one frame.
    public var weight: CGFloat

    public init(rect: CGRect, radius: CGFloat, group: Int, weight: CGFloat = 1) {
        self.rect = rect
        self.radius = radius
        self.group = group
        self.weight = min(max(weight, 0), 1)
    }
}

/// The metaball field: each shape adds `(1 - d / reach)^3` at signed distance `d` from its outline (more inside),
/// and the surface is where the field reaches 1. Far from every other shape a shape's outline is its own; near
/// another one of its group the two pull toward each other and join through a smooth neck. The falloff and its
/// sum are smooth, so the outline has no crease, fillet end or point anywhere.
public nonisolated struct GooField: Sendable {
    /// At most this many groups.
    public static let groupCount = 4
    private var midX: [CGFloat] = [], midY: [CGFloat] = [], halfW: [CGFloat] = [], halfH: [CGFloat] = []
    private var corner: [CGFloat] = []
    private var groups: [Int] = []
    private var weights: [CGFloat] = []
    public let shapes: [GooShape]
    public let reach: CGFloat
    /// 0: groups only meet (the larger group sum wins); 1: every shape adds, so groups flow into each other too.
    public var crossBlend: CGFloat

    public init(shapes: [GooShape], reach: CGFloat, crossBlend: CGFloat = 0) {
        self.shapes = shapes
        self.reach = max(1, reach)
        self.crossBlend = min(max(crossBlend, 0), 1)
        for shape in shapes {
            let rect = shape.rect.standardized
            midX.append(rect.midX)
            midY.append(rect.midY)
            halfW.append(rect.width / 2)
            halfH.append(rect.height / 2)
            corner.append(min(max(0, shape.radius), rect.width / 2, rect.height / 2))
            groups.append(min(max(0, shape.group), Self.groupCount - 1))
            weights.append(shape.weight)
        }
    }

    /// The field at a point, less 1: positive inside the surface.
    @inline(__always)
    public func value(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
        var sums = SIMD4<Double>(repeating: 0)
        let reach = self.reach
        for index in midX.indices {
            let r = corner[index]
            let qx = abs(x - midX[index]) - halfW[index] + r, qy = abs(y - midY[index]) - halfH[index] + r
            // Cheap reject: past the reach along either axis, it adds nothing.
            if qx - r >= reach || qy - r >= reach { continue }
            let ox = max(qx, 0), oy = max(qy, 0)
            let d = (ox * ox + oy * oy).squareRoot() + min(max(qx, qy), 0) - r
            let add: CGFloat
            if d <= 0 {
                add = 1 - 3 * d / reach
            } else if d >= reach {
                continue
            } else {
                let t = 1 - d / reach
                add = t * t * t
            }
            sums[groups[index]] += Double(add * weights[index])
        }
        let strongest = sums.max()
        return CGFloat(strongest + Double(crossBlend) * (sums.sum() - strongest)) - 1
    }
}

public nonisolated extension GooField {
    /// The surface: see `GooContour.surface`.
    func surface(plain: [GooShape], windows: [CGRect], step: CGFloat = 1) -> CGPath {
        GooContour.surface(self, plain: plain, windows: windows, step: step)
    }
}

/// Traces a `GooField`'s surface.
nonisolated enum GooContour {
    /// The surface: `plain` shapes, whose outline the field leaves as is (no other shape within reach), joined with
    /// the field's traced region inside each of `windows` (where shapes pull on each other). A window must reach
    /// past every interaction it holds by the field's reach, so its edge crosses only plain outlines: `windows`
    /// that overlap are merged first. The plain shapes must not overlap each other.
    static func surface(_ field: GooField, plain: [GooShape], windows: [CGRect], step: CGFloat = 1) -> CGPath {
        let base = CGMutablePath()
        for shape in plain where shape.rect.width > 0.5 && shape.rect.height > 0.5 && shape.weight >= 1 {
            let corner = min(shape.radius, shape.rect.width / 2, shape.rect.height / 2)
            base.addRoundedRect(in: shape.rect, cornerWidth: corner, cornerHeight: corner)
        }
        var surface: CGPath = base
        for window in merged(windows) {
            let loops = self.loops(field, in: window, step: step)
            guard !loops.isEmpty else { continue }
            let traced = CGMutablePath()
            for loop in loops where loop.count > 2 { traced.addLines(between: loop); traced.closeSubpath() }
            surface = surface.isEmpty ? traced : surface.union(traced, using: .evenOdd)
        }
        return surface
    }

    /// `rects` with every pair that overlaps replaced by their union, until none overlap.
    static func merged(_ rects: [CGRect]) -> [CGRect] {
        var out = rects.filter { !$0.isEmpty }
        var changed = true
        while changed {
            changed = false
            outer: for i in out.indices {
                for j in out.indices where j > i && out[i].intersects(out[j]) {
                    out[i] = out[i].union(out[j])
                    out.remove(at: j)
                    changed = true
                    break outer
                }
            }
        }
        return out
    }

    /// Marching squares over `window` every `step` points: the closed loops around where the field is positive. The
    /// grid's border samples count as outside, so every loop closes inside the window.
    static func loops(_ field: GooField, in window: CGRect, step: CGFloat) -> [[CGPoint]] {
        let x0 = (window.minX / step).rounded(.down) * step, y0 = (window.minY / step).rounded(.down) * step
        let nx = Int(((window.maxX - x0) / step).rounded(.up)) + 1, ny = Int(((window.maxY - y0) / step).rounded(.up)) + 1
        guard nx > 2, ny > 2, nx * ny < 4_000_000 else { return [] }
        var values = [CGFloat](repeating: -1, count: nx * ny)
        for j in 1..<(ny - 1) {
            let y = y0 + CGFloat(j) * step, row = j * nx
            for i in 1..<(nx - 1) { values[row + i] = field.value(x0 + CGFloat(i) * step, y) }
        }
        // Each crossed grid edge (horizontal: 2 * index, vertical: 2 * index + 1, by its lower-left sample) joins
        // the two segments that end on it.
        var links: [Int32: (Int32, Int32)] = [:]
        links.reserveCapacity(512)
        @inline(__always) func link(_ a: Int32, _ b: Int32) {
            if let pair = links[a] { links[a] = (pair.0, b) } else { links[a] = (b, -1) }
            if let pair = links[b] { links[b] = (pair.0, a) } else { links[b] = (a, -1) }
        }
        for j in 0..<(ny - 1) {
            for i in 0..<(nx - 1) {
                let ia = j * nx + i, ib = ia + 1, id = ia + nx, ic = id + 1
                let a = values[ia], b = values[ib], c = values[ic], d = values[id]
                var index = 0
                if a > 0 { index |= 1 }
                if b > 0 { index |= 2 }
                if c > 0 { index |= 4 }
                if d > 0 { index |= 8 }
                if index == 0 || index == 15 { continue }
                let bottom = Int32(2 * ia), right = Int32(2 * ib + 1), top = Int32(2 * id), left = Int32(2 * ia + 1)
                switch index {
                case 1, 14: link(left, bottom)
                case 2, 13: link(bottom, right)
                case 3, 12: link(left, right)
                case 4, 11: link(right, top)
                case 6, 9: link(bottom, top)
                case 7, 8: link(left, top)
                case 5:
                    if (a + b + c + d) / 4 > 0 { link(bottom, right); link(top, left) } else { link(left, bottom); link(right, top) }
                default: // 10
                    if (a + b + c + d) / 4 > 0 { link(left, bottom); link(right, top) } else { link(bottom, right); link(top, left) }
                }
            }
        }
        func point(_ edge: Int32) -> CGPoint {
            let sample = Int(edge >> 1), i = sample % nx, j = sample / nx
            let va = values[sample]
            if edge & 1 == 0 {
                let t = va / (va - values[sample + 1])
                return CGPoint(x: x0 + (CGFloat(i) + t) * step, y: y0 + CGFloat(j) * step)
            }
            let t = va / (va - values[sample + nx])
            return CGPoint(x: x0 + CGFloat(i) * step, y: y0 + (CGFloat(j) + t) * step)
        }
        var visited = Set<Int32>()
        visited.reserveCapacity(links.count)
        var loops: [[CGPoint]] = []
        for start in links.keys where !visited.contains(start) {
            var loop: [CGPoint] = []
            var previous: Int32 = -1, current = start
            while !visited.contains(current) {
                visited.insert(current)
                loop.append(point(current))
                guard let pair = links[current] else { break }
                let next = pair.0 == previous ? pair.1 : pair.0
                if next < 0 { break }
                previous = current
                current = next
            }
            if loop.count > 2 { loops.append(loop) }
        }
        return loops
    }
}
