public import CmuxNextDesign
public import CoreGraphics

/// How the rows below a new workspace row make room for it (Debug Settings `sidebar.insertMotion`). Leo
/// 2026-10-21: "sidebar i know it also pushes all the workspaces below down pretty hard so when you create a
/// workspace at the top it's a huge cascade". With `workspaces.newPlacement` `top` (the default) every new
/// workspace opens at the top of its section, so every row on screen moved one full row height on `.move`.
/// The versions differ only in how far the rows below travel and on which spring; Reduce Motion still moves
/// nothing (`RowMotion.run`), and every version ends on the springs' own settling time.
public nonisolated enum SidebarInsertMotion: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The nudge variant: the rows below travel at most `nudgeDistance` (6 pt) and the new row grows by as much
    /// while it fades in, on the short critically damped `.tabOpen` spring (no overshoot). It remains available
    /// for comparison; the shipped default is `.snap`, which keeps existing rows in their slots.
    case nudge
    /// The rows below travel their whole distance on the short `.tabOpen` spring (critically damped, about
    /// 130 ms to rest) instead of `.move`; the new row opens its slot and fades in.
    case quick
    /// No slide: the rows below are in their slots at once, and the new row fades in at its slot on `.tabOpen`.
    case snap
    /// The motion before this choice (#24187): the rows below travel their whole distance on `.move`.
    case spring

    public var tunableTitle: String {
        switch self {
        case .nudge: "Nudge (short, capped)"
        case .quick: "Quick spring"
        case .snap: "Snap, new row fades"
        case .spring: "Full spring"
        }
    }

    public static let tunable = Tunable<SidebarInsertMotion>.choice(
        "sidebar.insertMotion", .sidebar, "New row motion",
        help: "How the rows below a new workspace make room. Nudge: they travel at most the nudge distance on a short spring. Quick: their whole distance on a short spring. Snap: no slide, the new row fades in. Full spring: the motion before.",
        default: .snap, code: "SidebarInsertMotion.tunable")

    public static let nudgeDistance = Tunable<CGFloat>.number(
        "sidebar.insertMotion.nudge", .sidebar, "New row nudge distance",
        help: "Under the Nudge motion, the farthest a row below a new workspace travels to make room, and how much the new row grows. Never more than the new row's height.",
        default: 6, range: 0...40, step: 1, unit: .points, code: "SidebarInsertMotion.nudgeDistance")

    /// The spring the rows' frames and the new row's fade ride.
    public var token: MotionSpring { self == .spring ? .move : .tabOpen }

    /// The farthest an edge of a row travels: nil is its whole distance, 0 is none (the row is at its slot at once).
    public func travel(nudge: CGFloat) -> CGFloat? {
        switch self {
        case .nudge: max(0, nudge)
        case .snap: 0
        case .quick, .spring: nil
        }
    }

    /// `travel` (`travel(nudge:)`) no farther than `runHeight`, the height of the shortest run of new rows: a row below
    /// then never starts above the new rows' top, so it never crosses them or the row above them, however far it is
    /// drawn from its slot (a nudge set past a row's height, or an earlier move still in flight).
    public static func travel(_ travel: CGFloat?, within runHeight: CGFloat) -> CGFloat? {
        travel.map { min($0, max(0, runHeight)) }
    }

    /// The height of the shortest run of new rows: `runTops` maps each new row to the top of its run
    /// (`SidebarRowTransition.runTops`), `bottom` gives a row's bottom. Infinite when there is none.
    public static func shortestRun<Key: Hashable>(_ runTops: [Key: CGFloat], bottom: (Key) -> CGFloat?) -> CGFloat {
        var bottoms: [CGFloat: CGFloat] = [:]
        for (key, top) in runTops {
            guard let rowBottom = bottom(key) else { continue }
            bottoms[top] = max(bottoms[top] ?? top, rowBottom)
        }
        return bottoms.map { $0.value - $0.key }.min() ?? .infinity
    }

    /// `start` with each edge moved to within `travel` points of the same edge of `end`: a row below an insert
    /// starts that close to its slot, and a group line that ends at that row starts as close to its end.
    public static func cap(_ start: CGRect, toward end: CGRect, travel: CGFloat) -> CGRect {
        func near(_ value: CGFloat, _ target: CGFloat) -> CGFloat { min(max(value, target - travel), target + travel) }
        let minX = near(start.minX, end.minX), maxX = near(start.maxX, end.maxX)
        let minY = near(start.minY, end.minY), maxY = near(start.maxY, end.maxY)
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// Where a new row starts. `opening` is where it would open from (`SidebarRowTransition.insertFrame`): zero
    /// height at the top of its run of new rows, or whole under a header that unfolds it. Nudge opens the run to
    /// its height less the nudge, so its bottom meets the first row below where that row starts; snap starts at
    /// the slot. A row under an unfolding header keeps its start.
    public func openFrame(_ opening: CGRect, target: CGRect, nudge: CGFloat) -> CGRect {
        switch self {
        case .snap:
            return target
        case .nudge where opening.height == 0 && opening.minY <= target.minY:
            let runTop = opening.minY
            let top = max(runTop, target.minY - max(0, nudge)), bottom = max(runTop, target.maxY - max(0, nudge))
            return CGRect(x: target.minX, y: top, width: target.width, height: bottom - top)
        default:
            return opening
        }
    }
}
