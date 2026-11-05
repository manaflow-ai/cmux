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

    /// Where the leftmost tab meets the card's leading edge (`chrome.gooMorph.corner`): Leo, "either ... the
    /// divider curves up right there, and ... the tab presses up right on that divider ... completely flush. Or
    /// ... the tab at its left, when it's at the leftmost on that left area, is just square".
    public static let corner = Tunable<GooCorner>.choice(
        "chrome.gooMorph.corner", .sidebar, "Goo morph corner",
        help: "Where the leftmost tab meets the card's edge: the edge curves up into the tab, or the tab is square there.",
        default: .curve, code: "GooMorphVariant.corner")

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

/// How the leftmost tab's droplet meets the card's leading edge (`GooMorphVariant.corner`).
public nonisolated enum GooCorner: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The edge runs straight up into the tab and turns with the tab's own radius.
    case curve
    /// The edge runs straight up into the tab, which is square there.
    case square

    public var tunableTitle: String {
        switch self {
        case .curve: "Curve: the edge curves up into the tab"
        case .square: "Square: the tab is square at the edge"
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
    private var wall: (midX: CGFloat, midY: CGFloat, halfW: CGFloat, halfH: CGFloat, r: CGFloat)?
    private var wallStrength: CGFloat = 0
    public let shapes: [GooShape]
    public let reach: CGFloat
    /// 0: groups only meet (the larger group sum wins); 1: every shape adds, so groups flow into each other too.
    public var crossBlend: CGFloat

    /// `wall`: group 0 stays inside it (by `wallStrength`, 0 to 1), so a droplet pressed on its edge is cut flat
    /// there, flush with the card, instead of bulging past it.
    public init(shapes: [GooShape], reach: CGFloat, crossBlend: CGFloat = 0, wall: GooShape? = nil, wallStrength: CGFloat = 1) {
        self.shapes = shapes
        self.reach = max(1, reach)
        self.crossBlend = min(max(crossBlend, 0), 1)
        if let wall {
            let rect = wall.rect.standardized
            self.wall = (rect.midX, rect.midY, rect.width / 2, rect.height / 2, min(max(0, wall.radius), rect.width / 2, rect.height / 2))
            self.wallStrength = min(max(wallStrength, 0), 1)
        }
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
        // Four scalar group sums: a SIMD vector is a generic call per lane in a Debug build.
        var s0: CGFloat = 0, s1: CGFloat = 0, s2: CGFloat = 0, s3: CGFloat = 0
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
            switch groups[index] {
            case 0: s0 += add * weights[index]
            case 1: s1 += add * weights[index]
            case 2: s2 += add * weights[index]
            default: s3 += add * weights[index]
            }
        }
        if let wall, wallStrength > 0 {
            // Past the wall, group 0 falls off linearly with the distance (2 per point), so the traced edge lands on
            // the wall exactly, between samples too.
            let d = Self.distance(x, y, wall.midX, wall.midY, wall.halfW, wall.halfH, wall.r)
            s0 += wallStrength * (min(s0, 1 - 2 * d) - s0)
        }
        let strongest = max(s0, s1, s2, s3)
        return strongest + crossBlend * (s0 + s1 + s2 + s3 - strongest) - 1
    }

    /// Signed distance from a rounded rect's outline (negative inside).
    @inline(__always)
    static func distance(_ x: CGFloat, _ y: CGFloat, _ midX: CGFloat, _ midY: CGFloat, _ halfW: CGFloat, _ halfH: CGFloat, _ r: CGFloat) -> CGFloat {
        let qx = abs(x - midX) - halfW + r, qy = abs(y - midY) - halfH + r
        let ox = max(qx, 0), oy = max(qy, 0)
        return (ox * ox + oy * oy).squareRoot() + min(max(qx, qy), 0) - r
    }
}

public nonisolated extension GooField {
    /// The surface: see `GooContour.surface`.
    func surface(plain: [GooShape], windows: [CGRect], step: CGFloat = 2) -> CGPath {
        GooContour.surface(self, plain: plain, windows: windows, step: step)
    }
}

/// Traces a `GooField`'s surface.
nonisolated enum GooContour {
    /// The surface: `plain` shapes, whose outline the field leaves as is (no other shape within reach), and the
    /// field's region outside them inside each of `windows` (where shapes pull on each other). A window must reach
    /// past every interaction it holds by the field's reach; `windows` that overlap are merged first. The plain
    /// shapes must not overlap each other. Every piece is disjoint from the others (a traced region stops on a
    /// plain outline, exactly), so the path needs no boolean op: even-odd or nonzero fill it the same.
    static func surface(_ field: GooField, plain: [GooShape], windows: [CGRect], step: CGFloat = 2) -> CGPath {
        let path = CGMutablePath()
        var masks: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = []
        for shape in plain where shape.rect.width > 0.5 && shape.rect.height > 0.5 && shape.weight >= 1 {
            let rect = shape.rect.standardized
            let corner = min(shape.radius, rect.width / 2, rect.height / 2)
            path.addRoundedRect(in: rect, cornerWidth: corner, cornerHeight: corner)
            masks.append((rect.midX, rect.midY, rect.width / 2, rect.height / 2, corner))
        }
        for window in merged(windows) {
            for loop in loops(field, masks: masks, in: window, step: step) where loop.count > 2 {
                path.addLines(between: loop)
                path.closeSubpath()
            }
        }
        return path
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

    /// Marching squares over `window` every `step` points: the closed loops around where the field is positive and
    /// outside every mask (the plain shapes: past a mask's outline the value falls linearly, so a loop runs on it
    /// exactly). The grid's border samples count as outside, so every loop closes inside the window.
    static func loops(_ field: GooField, masks: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [], in window: CGRect,
                      step: CGFloat) -> [[CGPoint]] {
        let x0 = (window.minX / step).rounded(.down) * step, y0 = (window.minY / step).rounded(.down) * step
        let nx = Int(((window.maxX - x0) / step).rounded(.up)) + 1, ny = Int(((window.maxY - y0) / step).rounded(.up)) + 1
        guard nx > 2, ny > 2, nx * ny < 1_000_000 else { return [] }
        var values = [CGFloat](repeating: -1, count: nx * ny)
        for j in 1..<(ny - 1) {
            let y = y0 + CGFloat(j) * step, row = j * nx
            for i in 1..<(nx - 1) {
                let x = x0 + CGFloat(i) * step
                var value = field.value(x, y)
                if value > 0 {
                    for mask in masks {
                        value = min(value, 2 * GooField.distance(x, y, mask.0, mask.1, mask.2, mask.3, mask.4))
                    }
                }
                values[row + i] = value
            }
        }
        // Each crossed grid edge (horizontal: 2 * index, vertical: 2 * index + 1, by its lower-left sample) joins
        // the two segments that end on it: flat arrays, -1 for none.
        var first = [Int32](repeating: -1, count: 2 * nx * ny), second = first
        var crossed: [Int32] = []
        @inline(__always) func attach(_ a: Int32, _ b: Int32) {
            let i = Int(a)
            if first[i] < 0 { first[i] = b; crossed.append(a) } else { second[i] = b }
        }
        @inline(__always) func link(_ a: Int32, _ b: Int32) { attach(a, b); attach(b, a) }
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
        var visited = [Bool](repeating: false, count: first.count)
        var loops: [[CGPoint]] = []
        for start in crossed where !visited[Int(start)] {
            var loop: [CGPoint] = []
            var previous: Int32 = -1, current = start
            while current >= 0, !visited[Int(current)] {
                visited[Int(current)] = true
                loop.append(point(current))
                let next = first[Int(current)] == previous ? second[Int(current)] : first[Int(current)]
                previous = current
                current = next
            }
            if loop.count > 2 { loops.append(loop) }
        }
        return loops
    }
}
