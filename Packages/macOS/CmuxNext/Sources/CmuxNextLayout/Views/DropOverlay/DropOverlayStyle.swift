public import CmuxNextDesign

/// How the drop overlay shows where a dragged tab will land
/// (`drop.overlay.style` in Debug Settings). Every style keeps the same
/// hit testing and commit; only the drawing differs. Glass styles fall
/// back to a blur or an opaque fill (`OverlayMaterial`), and every style
/// snaps instead of moving under Reduce Motion.
public nonisolated enum DropOverlayStyle: String, Sendable, CaseIterable, TunableChoice {
    /// A rounded accent border exactly around the future rect, no fill,
    /// moved by the compositor (tab-dnd default, Lawrence 2026-10-04: "i
    /// dont like solid thing, id rather just draw the border").
    case outline
    /// Real Liquid Glass filling the target region (the original look).
    case glassFill
    /// A band of glass tracing the target's edge, the content visible inside.
    case glassOutline
    /// A faint region tint with a glass card in its middle naming the drop.
    case insetCard
    /// The two panes the drop creates, at their final sizes, with a gap.
    case splitPreview
    /// A thick rounded caret where the new divider (or tab strip) appears.
    case insertionLine
    /// A soft glow growing inward from the edge the new pane takes.
    case edgeGlow
    /// A tab-shaped pill where the tab will sit in the destination's strip.
    case tabGhost
    /// Everything except the target dimmed, like a spotlight.
    case dimOthers
    /// Glass that grows from the pointer into the target and morphs
    /// between targets with the settle spring.
    case morph
    /// A one-pixel frame, nothing else.
    case hairline
    /// A dashed outline.
    case dashed
    /// Viewfinder brackets at the target's four corners.
    case corners

    public var tunableTitle: String {
        switch self {
        case .outline: "Outline"
        case .glassFill: "Liquid Glass fill"
        case .glassOutline: "Glass outline"
        case .insetCard: "Inset glass card"
        case .splitPreview: "Split preview"
        case .insertionLine: "Insertion line"
        case .edgeGlow: "Edge glow"
        case .tabGhost: "Tab at destination"
        case .dimOthers: "Spotlight (dim others)"
        case .morph: "Morph from pointer"
        case .hairline: "Hairline frame"
        case .dashed: "Dashed outline"
        case .corners: "Corner brackets"
        }
    }

    /// Whether the style draws Liquid Glass (and so follows `OverlayMaterial`).
    public var usesGlass: Bool {
        switch self {
        case .glassFill, .glassOutline, .insetCard, .splitPreview, .tabGhost, .morph: true
        case .outline, .insertionLine, .edgeGlow, .dimOthers, .hairline, .dashed, .corners: false
        }
    }

    /// The style the overlay draws now (the tunable; default `outline`).
    public static var current: DropOverlayStyle { DropOverlayTunables.style.value }
}
