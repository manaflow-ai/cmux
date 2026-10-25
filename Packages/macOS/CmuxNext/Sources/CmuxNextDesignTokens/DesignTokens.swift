public import CoreGraphics

/// The cross-platform design scale shared by webview CSS and native chrome.
///
/// Existing density metrics remain tunable; these values are the stable names new surfaces use
/// while a surface is migrated. The popup aliases in `PopupStyle` intentionally resolve to the
/// same values they had before this scale was introduced.
public struct DesignTokens: Sendable {
    public init() {}

    public static let space1: CGFloat = 4
    public static let space2: CGFloat = 8
    public static let space3: CGFloat = 12
    public static let space4: CGFloat = 16
    public static let space5: CGFloat = 24
    public static let space6: CGFloat = 32

    public static let controlIcon: CGFloat = 20
    public static let controlCompact: CGFloat = 24
    public static let controlRow: CGFloat = 28
    public static let controlPrimary: CGFloat = 32

    public static let radiusControl: CGFloat = 6
    public static let radiusPopup: CGFloat = 8
    public static let radiusCard: CGFloat = 14
    public static let radiusComposer: CGFloat = 18

    public static let glassPlainTint: CGFloat = 0.6
    public static let glassPlainBlur: CGFloat = 20
    public static let glassLensTint: CGFloat = 0.4
    public static let glassLensBlur: CGFloat = 6
}
