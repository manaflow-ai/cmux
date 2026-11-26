public import AppKit
public import CmuxNextDesignTokens

/// The one surface every hover surface draws on: tooltips (``TooltipPanel``, the web pages' host
/// tooltip glass), hover cards (``HoverCardPanel``) and the hint toasts (the standard ``CmuxToastView``:
/// the terminal's selection hint, the closed-tab undo toast).
///
/// Leo 2026-11-24, of the closed-tab toast and the selection hint: "this ui is also there for the closed
/// recent tab thing and has the same pitfalls (wack ass glass, affected by layout shifts when it shouldnt
/// be, etc." So these surfaces draw solid by default: the theme's popup surface (``Palette/popupSurface``,
/// the opaque overlay fill), an edge and a shadow from the elevation tokens, so their text keeps its full
/// contrast over any terminal. Each surface keeps its own content and motion. The glass they drew before
/// is still the ``glass`` value of the setting (Debug Settings > Glass and Overlays > Hover surfaces).
public nonisolated enum HoverSurfaceLook: String, Sendable, CaseIterable, TunableChoice {
    /// Gallery 1 (default): the popup surface with the device-pixel separator hairline and each surface's
    /// own shadow.
    case hairline
    /// Gallery 2: the popup surface with no edge, lifted by the second elevation alone.
    case shadowed
    /// Gallery 3: the popup surface with a one-point separator rim and the second elevation.
    case framed
    /// The glass these surfaces drew before (Liquid Glass, the blur before macOS 26).
    case glass

    public var tunableTitle: String {
        switch self {
        case .hairline: "1: Solid, hairline edge"
        case .shadowed: "2: Solid, shadow only"
        case .framed: "3: Solid, one-point rim"
        case .glass: "Glass (before)"
        }
    }

    /// The looks the gallery shows side by side.
    public static let solidLooks: [HoverSurfaceLook] = [.hairline, .shadowed, .framed]

    /// Whether the look paints the opaque popup surface.
    public var isSolid: Bool { self != .glass }

    /// Debug Settings > Glass and Overlays > Hover surfaces; Release keeps `hairline`.
    public static let tunable = Tunable<HoverSurfaceLook>.choice(
        "glass.hoverSurface", .glass, "Hover surfaces",
        help: "What tooltips, hover cards and hint toasts draw on: the solid popup surface (default) with a hairline, a shadow only or a one-point rim, or the glass they drew before.",
        default: .hairline, code: "HoverSurfaceLook.tunable")

    /// The look the hover surfaces draw now: the setting (a test pins one through the tunable store).
    @MainActor public static var current: HoverSurfaceLook { tunable.value }

    /// The material the look pins: the opaque popup surface, or nil (the glass follows this Mac).
    public var material: OverlayMaterial? { isSolid ? .opaque : nil }

    /// The edge the solid surface draws, in points (nil: the device-pixel hairline).
    public var edgeWidth: CGFloat? {
        switch self {
        case .hairline, .glass: nil
        case .shadowed: 0
        case .framed: 1
        }
    }

    /// The shadow a surface casts in this look, given the one it casts by default.
    @MainActor public func shadow(default base: Elevation) -> Elevation {
        switch self {
        case .hairline, .glass: base
        case .shadowed, .framed: PopupStyle.elevation2
        }
    }

    /// Puts the look on a surface: the solid looks pin the opaque material and their edge; glass
    /// gives the material back to this Mac.
    @MainActor public func apply(to surface: OverlaySurfaceView) {
        surface.edgeWidth = edgeWidth
        surface.materialOverride = material
    }
}
