/// The look of the floating glass (toasts, dialogs and sheets: the neutral glass that casts a shadow), by
/// its number in the glass variant gallery (18 numbered looks over a busy page, light and dark, on every
/// surface; Lawrence 2026-11-10: "take screenshots with every variation possible and ill point out the one
/// that looks like proper liquid glass"). ``picked`` is the one line that applies another pick everywhere.
///
/// Reduce Transparency keeps the opaque surface whatever the variant; before macOS 26 the blur stands in
/// for Liquid Glass.
public nonisolated enum OverlayGlassVariant: Int, Sendable, CaseIterable {
    /// 1: Apple's Liquid Glass as it ships (`NSGlassEffectView`, `.regular`): no veil tint, and the glass's
    /// own edge with no second rim over it.
    case appKitRegular = 1
    /// 3: Liquid Glass with the role's veil as its tint and the neutral rim (the look before 2026-11-10).
    case veilTinted = 3
    /// 11: the frosted blur (`NSVisualEffectView`, `.popover`) with the veil painted on it and the rim.
    case frost = 11

    /// The floating surfaces' variant. Change this one line to apply another gallery pick everywhere.
    public static let picked: OverlayGlassVariant = .appKitRegular

    /// Whether the role's veil tints the glass.
    var tintsGlass: Bool { self != .appKitRegular }
    /// Whether the neutral rim draws over the glass's own edge.
    var drawsRim: Bool { self != .appKitRegular }
    /// Whether the frosted blur stands where this Mac would draw Liquid Glass.
    var prefersFrost: Bool { self == .frost }
}
