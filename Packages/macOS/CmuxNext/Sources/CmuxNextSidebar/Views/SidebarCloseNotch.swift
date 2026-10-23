import CmuxNextDesign
import CoreGraphics

/// The corner a workspace row's hover close chops out of the row's fill (Leo 2026-10-22, on the
/// dog-ear: "i wanted the hoverable area to just... not have it on the top right corner. a smaller top
/// right corner not higlighitng bc the button itself chopped off that top right"). The row's hover
/// (or selection) fill leaves out a small square around the x, so the highlight reads as the row with
/// its corner cut away by the button; nothing draws in the cut but the x, and the x keeps its place.
/// The other gallery versions stay in Debug Settings (`sidebar.closeNotch`).
nonisolated enum SidebarCloseNotch: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// A rounded cut that hugs the x, with even room around it (the pick: the smallest corner that
    /// still reads as the button's own).
    case snug
    /// The same cut with square corners.
    case square
    /// A rounded cut the size of the x's old hit box (the dog-ear's square).
    case hitBox
    /// The snug cut with a hairline along its edge.
    case hairline

    var tunableTitle: String {
        switch self {
        case .snug: "Snug rounded cut"
        case .square: "Snug square cut"
        case .hitBox: "Rounded cut, hit box size"
        case .hairline: "Snug rounded cut with a hairline"
        }
    }

    static let tunable = Tunable<SidebarCloseNotch>.choice(
        "sidebar.closeNotch", .sidebar, "Row close corner",
        help: "How a workspace row's hover close cuts the row's top-right corner out of its fill: snug (rounded or square), the size of the old dog-ear, or snug with a hairline edge.",
        default: .snug, code: "SidebarCloseNotch.tunable")

    /// The cut's side, for the dog-ear square `side` the x is placed in: twice the x's distance from
    /// the row's top and right edges, so the x sits centered in it; or the whole square.
    func side(dogEar side: CGFloat) -> CGFloat { self == .hitBox ? side : (side * 0.6).rounded() }

    /// The radius of the cut's three corners, for a row of `rowRadius`.
    func cornerRadius(rowRadius: CGFloat) -> CGFloat { self == .square ? 0 : (rowRadius / 2).rounded() }

    /// Everything the cut takes from the row in `rect` (flipped): its `side` square, and past it the
    /// fillets of `radius` where the cut meets the row's top edge (to its left) and right edge (below
    /// it). The close's frame, so its hit area can cover the whole drawn cut (`SidebarDogEarButton`).
    static func cutFrame(in rect: CGRect, side: CGFloat, radius: CGFloat) -> CGRect {
        let r = max(0, min(radius, side / 2))
        return CGRect(x: rect.maxX - side - r, y: rect.minY, width: side + r, height: side + r)
    }

    /// The row's fill in `rect` (flipped) with its top-right `side` square cut out, the cut's corners
    /// rounded by `radius`. The fill layer clips the row's own corners.
    static func fillPath(in rect: CGRect, side: CGFloat, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        addCut(to: path, in: rect, side: side, radius: radius)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    /// The cut's edge alone, from the row's top edge to its right edge, for the hairline.
    static func edgePath(in rect: CGRect, side: CGFloat, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.maxX - side - max(0, min(radius, side / 2)), y: rect.minY))
        addCut(to: path, in: rect, side: side, radius: radius)
        return path
    }

    /// Along the top to the cut, down its left side, along its bottom and onto the right edge below it.
    private static func addCut(to path: CGMutablePath, in rect: CGRect, side: CGFloat, radius: CGFloat) {
        let left = rect.maxX - side, bottom = rect.minY + side
        let r = max(0, min(radius, side / 2))
        path.addLine(to: CGPoint(x: left - r, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: left, y: rect.minY), tangent2End: CGPoint(x: left, y: bottom), radius: r)
        path.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: rect.maxX, y: bottom), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: bottom), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: r)
        path.addLine(to: CGPoint(x: rect.maxX, y: bottom + r))
    }
}
