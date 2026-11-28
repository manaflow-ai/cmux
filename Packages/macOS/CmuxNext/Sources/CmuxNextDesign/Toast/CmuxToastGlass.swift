public import CmuxNextDesignTokens

/// The glass a toast draws on, by its glass gallery number (``OverlayGlassVariant``), as a Debug Settings
/// choice (``CmuxToastTunables/glass``).
///
/// The default is the veil-tinted Liquid Glass (gallery 3): real Liquid Glass, with the toast role's veil
/// under the text. The clear glass (gallery 1) read worse than the old frost over a busy page (Lawrence
/// 2026-11-09: "before looks more readable"), and toasts are text first.
public nonisolated enum CmuxToastGlass: String, Sendable, CaseIterable, TunableChoice {
    /// Gallery 1: Apple's Liquid Glass as it ships, no veil and no second rim: the glass every other native
    /// overlay draws (``OverlayGlassVariant/picked``, `.appKitRegular`), so picking it shows a toast that
    /// matches the menus, popovers and dialogs (RFD 0207 "Native toast glass variant"). Not the default:
    /// flipping it needs Leo's word.
    case liquid
    /// Gallery 3: Liquid Glass tinted with the toast role's veil, with the neutral rim.
    case liquidVeil
    /// Gallery 11: the frosted blur with the veil and the rim.
    case frost

    public var tunableTitle: String {
        switch self {
        case .liquid: "1: Liquid Glass, clear (as the other overlays)"
        case .liquidVeil: "3: Liquid Glass with the veil (readable)"
        case .frost: "11: Frosted blur with the veil"
        }
    }

    /// The overlay surface's variant for this glass.
    public var variant: OverlayGlassVariant {
        switch self {
        case .liquid: .appKitRegular
        case .liquidVeil: .veilTinted
        case .frost: .frost
        }
    }
}
