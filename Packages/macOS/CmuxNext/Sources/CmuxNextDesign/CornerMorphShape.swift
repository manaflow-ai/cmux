public import CmuxNextDesignTokens
public import CoreGraphics

// Leo 2026-11-05, on the corner where the sidebar's + and workspaces meet the rounded tabs: "you can't
// mix straight with curved, you just can't ... We need to have a way to morph it together ... we can
// keep all of the space ... we can just like fake the morph". Debug `sidebar.cornerMorph`.

/// What joins the main pane's card at its sidebar edge: rects in the chrome shade's coordinates that
/// become one surface with the card. Nothing moves; only the shade's cut-out changes shape, so the
/// card's surface (the window's own backdrop) runs into the sidebar.
public nonisolated struct CornerMorph: Equatable, Sendable {
    /// The sidebar's titlebar row (traffic lights, the +), from the window's leading gutter to the
    /// card's leading edge, at the card's top: with the card's top row of tabs it reads as one band, and
    /// the workspace list sits in a recess under it.
    public var header: CGRect?
    /// The selected workspace row's pill: joined to the card's leading edge through the gutter, the
    /// way a selected Chrome tab joins its toolbar.
    public var row: CGRect?
    /// The corner radius of the row pill.
    public var rowRadius: CGFloat
    /// The radius of the concave fillets where an attachment meets the card's straight edge.
    public var fillet: CGFloat

    public init(header: CGRect? = nil, row: CGRect? = nil, rowRadius: CGFloat, fillet: CGFloat) {
        self.header = header
        self.row = row
        self.rowRadius = rowRadius
        self.fillet = fillet
    }

    public var isEmpty: Bool { header == nil && row == nil }
}

public extension CornerMorph {
    /// The card (rounded by `radius`) and every attachment, as one path. The card sits on the
    /// trailing side of its attachments when `leading` is true (a left sidebar), else on the leading side.
    /// Works in flipped and unflipped coordinates alike: only x is directional.
    func surface(card: CGRect, radius: CGFloat, leading: Bool = true) -> CGPath {
        let corner = min(radius, card.width / 2, card.height / 2)
        var shape: CGPath = CGPath(roundedRect: card, cornerWidth: corner, cornerHeight: corner, transform: nil)
        let edgeX = leading ? card.minX : card.maxX
        // The shell's far corners match the card's own (one shape, one radius); the row keeps its pill's.
        for (attachment, round) in [(header, corner), (row, rowRadius)] {
            guard let attachment, let joined = join(attachment, card: card, corner: corner, round: round, edgeX: edgeX, leading: leading) else { continue }
            shape = shape.union(joined)
        }
        return shape
    }

    /// One attachment widened to the card's edge, its far corners rounded, plus a concave fillet at each
    /// end that lands on the card's straight edge. An end level with the card's top or bottom edge
    /// merges with it (the card's corner there squares off, covered by the attachment).
    internal func join(_ rect: CGRect, card: CGRect, corner: CGFloat, round: CGFloat, edgeX: CGFloat, leading: Bool) -> CGPath? {
        let minY = max(rect.minY, card.minY), maxY = min(rect.maxY, card.maxY)
        guard maxY - minY >= 1 else { return nil }
        let farX = leading ? rect.minX : rect.maxX
        guard leading ? farX < edgeX : farX > edgeX else { return nil }
        let r = min(round, (maxY - minY) / 2, abs(edgeX - farX))
        // Into the card past its corner arc and the body's own inner corner, so neither leaves a notch.
        let reach = min(corner + r + 1, card.width / 2)
        let body = CGRect(x: leading ? farX : edgeX - reach, y: minY,
                          width: abs(edgeX - farX) + reach, height: maxY - minY)
        let path = CGMutablePath()
        path.addPath(CGPath(roundedRect: body, cornerWidth: r, cornerHeight: r, transform: nil))
        let f = min(fillet, abs(edgeX - farX) - r)
        // An end level with the card's top or bottom merges with that edge; any other end needs room on the card's
        // straight edge for its fillet, or the join is left out (the card's own corner would show a notch).
        let lowLevel = minY <= card.minY + 0.5, highLevel = maxY >= card.maxY - 0.5
        let lowFits = f >= 0.5 && minY - f >= card.minY + corner - 0.5
        let highFits = f >= 0.5 && maxY + f <= card.maxY - corner + 0.5
        guard lowLevel || lowFits, highLevel || highFits else { return nil }
        if !lowLevel { Self.addFillet(to: path, edgeX: edgeX, y: minY, towardCard: leading, away: -1, f: f) }
        if !highLevel { Self.addFillet(to: path, edgeX: edgeX, y: maxY, towardCard: leading, away: 1, f: f) }
        return path
    }

    /// The concave fillet between an attachment's horizontal edge at `y` and the card's vertical edge at
    /// `edgeX`, on the attachment's side, reaching `f` along both: the square there minus the circle
    /// whose center is `f` from both edges.
    internal static func addFillet(to path: CGMutablePath, edgeX: CGFloat, y: CGFloat, towardCard: Bool, away: CGFloat, f: CGFloat) {
        let outX = towardCard ? edgeX - f : edgeX + f
        path.move(to: CGPoint(x: edgeX, y: y + away * f))
        path.addArc(tangent1End: CGPoint(x: edgeX, y: y), tangent2End: CGPoint(x: outX, y: y), radius: f)
        path.addLine(to: CGPoint(x: edgeX, y: y))
        path.closeSubpath()
    }
}

/// How the top-left corner joins the sidebar to the main pane's card (Debug `sidebar.cornerMorph`).
///
/// Leo 2026-11-05: "There's just this extremely awful corner area where it's like, okay, you have this plus
/// symbol, and then you have the divider, and then you have like the workspaces, and then you have the top
/// horizontal tab ... We need to have a way to morph it together." Nothing moves and nothing is added: only the
/// chrome shade's cut-out changes shape (`CornerMorph`), so the card's surface runs into the sidebar. Applies at
/// the comfortable and expanded sidebar densities only; compact (Lawrence's) keeps the plain card.
public nonisolated enum CornerMorphVariant: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The plain card beside the sidebar, as before.
    case off
    /// The sidebar's titlebar row (traffic lights, the +) and the card's row of tabs are one band; the workspace
    /// list sits in a recess under it, its corner a concave fillet into the card's edge.
    case shell
    /// The selected workspace row joins the card through the gutter, with concave fillets above and below where
    /// it meets the card's edge: the selected workspace reads as the tab that owns the content, the way a selected
    /// Chrome tab flows into its toolbar.
    case bridge
    /// `shell` and `bridge` together: the +, the tabs and the selected workspace on one surface.
    case both

    public var tunableTitle: String {
        switch self {
        case .off: "Off: plain card"
        case .shell: "Shell: titlebar row and tabs as one band"
        case .bridge: "Bridge: selected workspace joins the card"
        case .both: "Shell and bridge"
        }
    }

    public var joinsHeader: Bool { self == .shell || self == .both }
    public var joinsSelectedRow: Bool { self == .bridge || self == .both }

    public static let tunable = Tunable<CornerMorphVariant>.choice(
        "sidebar.cornerMorph", .sidebar, "Corner morph",
        help: "Joins the sidebar's corner to the main pane as one shape (comfortable and expanded sidebar density): the titlebar row and the tabs as one band, the selected workspace joined to the pane, or both.",
        default: .off, code: "CornerMorphVariant.tunable")

    /// What the window's main pane observation follows for the morph: the variant and the sidebar density that gates it.
    @MainActor public static var observedInputs: [CGFloat] {
        // Off reads nothing more than the variant, so the plain card's observation is as before.
        let variant = tunable.value
        guard variant != .off else { return [0] }
        return [CGFloat(allCases.firstIndex(of: variant) ?? 0),
                CGFloat(SidebarDensity.allCases.firstIndex(of: DesignSettings.shared.sidebarSections.density) ?? 0)]
    }

    /// The shade under a morph: the default flat chrome (`flatSidebarLine`) and the shared surface shade nothing,
    /// which would leave the joined shape invisible, so a morph brings the separate look's tint
    /// (`chrome.mainPane.shadeLight` / `shadeDark`) over the sidebar, as Arc tints its sidebar beside the content,
    /// and the sidebar's edge hairline steps aside for it. Only while a morph variant is on.
    @MainActor public func shade(_ alpha: CGFloat, isDark: Bool) -> CGFloat {
        guard self != .off, alpha == 0 else { return alpha }
        return CGFloat((isDark ? ChromeTunables.mainPaneShadeDark : ChromeTunables.mainPaneShadeLight).value)
    }
}
