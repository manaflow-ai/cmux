public import CoreGraphics

/// The cross-platform design scale shared by webview CSS and native chrome.
///
/// Existing density metrics remain tunable; these values are the stable names new surfaces use
/// while a surface is migrated. The popup aliases in `PopupStyle` intentionally resolve to the
/// same values they had before this scale was introduced.
///
/// Every value forwards to `DesignScale`, which the build generates from
/// schemas/design-scale/design-scale.json (scripts/cmux-next/gen-design-scale-swift.py, the
/// DesignScalePlugin), the same file the webviews' `--ds-*` tokens come from. A native value that
/// differs from the JSON today is `DesignScale.NativeOverride`.
public struct DesignTokens: Sendable {
    public init() {}

    public static let space1: CGFloat = DesignScale.space1
    public static let space2: CGFloat = DesignScale.space2
    public static let space3: CGFloat = DesignScale.space3
    public static let space4: CGFloat = DesignScale.space4
    public static let space5: CGFloat = DesignScale.space5
    public static let space6: CGFloat = DesignScale.space6

    public static let controlIcon: CGFloat = DesignScale.controlIcon
    public static let controlCompact: CGFloat = DesignScale.controlCompact
    public static let controlRow: CGFloat = DesignScale.controlRow
    public static let controlPrimary: CGFloat = DesignScale.controlPrimary

    public static let radiusControl: CGFloat = DesignScale.NativeOverride.radiusControl
    public static let radiusPopup: CGFloat = DesignScale.radiusPopup
    public static let radiusCard: CGFloat = DesignScale.radiusCard
    public static let radiusComposer: CGFloat = DesignScale.radiusComposer

    public static let glassPlainTint: CGFloat = DesignScale.NativeOverride.glassPlainTint
    public static let glassPlainBlur: CGFloat = DesignScale.glassChromeBlur
    public static let glassLensTint: CGFloat = DesignScale.glassLensTint
    public static let glassLensBlur: CGFloat = DesignScale.glassLensBlur
}
