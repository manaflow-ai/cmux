public import AppKit
public import SwiftUI

/// Where cmux's own chrome takes its typeface from.
///
/// The terminal is the part of cmux people configure, and a sidebar drawn in
/// the system font next to a terminal drawn in the user's font reads as two
/// applications stacked side by side. `terminal` is the default so the chrome
/// follows the font already configured for Ghostty; `system` is the escape
/// hatch for people who want the terminal font only in the terminal; an
/// explicit family covers the case where the chrome should use a third font.
///
/// Stored as a single string setting, so the two named cases are reserved
/// words: a font family literally named "terminal" or "system" cannot be
/// selected by name. Every other value is read as a family name.
public enum CmuxChromeFontSource: Sendable, Hashable {
    case terminal
    case system
    case explicit(String)

    public static let terminalSettingValue = "terminal"
    public static let systemSettingValue = "system"

    /// Reads the stored setting. An empty or whitespace-only value means the
    /// setting was cleared, which is the default rather than an error.
    public init(settingValue: String) {
        let trimmed = settingValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "", Self.terminalSettingValue:
            self = .terminal
        case Self.systemSettingValue:
            self = .system
        default:
            self = .explicit(trimmed)
        }
    }

    public var settingValue: String {
        switch self {
        case .terminal:
            return Self.terminalSettingValue
        case .system:
            return Self.systemSettingValue
        case .explicit(let family):
            return family
        }
    }
}

/// The typeface chrome text is drawn with, once the setting and the machine's
/// installed fonts have both been taken into account.
///
/// `monospacedSystem` exists because it is what the terminal itself falls back
/// to when the configured family cannot be drawn here. Following the terminal
/// has to mean following it into its fallback as well, otherwise the one
/// population that sees a mismatched sidebar is the population missing a font,
/// which is the least likely to be looking for it.
///
/// Both sidebar renderers build their fonts from this one descriptor, so a
/// family that resolves one way in the AppKit path cannot resolve another way in
/// the SwiftUI path.
///
/// Point sizes are deliberately not decided here. Callers pass a size that has
/// already been through the sidebar font scale and the global font
/// magnification, exactly as they did when every one of these labels called
/// `NSFont.systemFont(ofSize:weight:)` directly, so changing the family cannot
/// quietly opt the chrome out of accessibility text sizing.
public enum CmuxChromeTypeface: Sendable, Hashable {
    case system
    case monospacedSystem
    case family(String)

    /// The typeface the chrome should draw with.
    ///
    /// `terminalFamilies` is the ordered list of families configured for the
    /// terminal, most preferred first. A Ghostty config may name several and
    /// may name none, so the first one that is actually installed wins, and a
    /// list with nothing drawable in it lands on the terminal's own fallback.
    public static func resolved(
        source: CmuxChromeFontSource,
        terminalFamilies: [String],
        isInstalled: (String) -> Bool = CmuxChromeTypeface.isFamilyInstalled
    ) -> CmuxChromeTypeface {
        switch source {
        case .system:
            return .system
        case .explicit(let family):
            // The user named a chrome font. If it is not on this machine the
            // chrome goes back to its own font rather than to the terminal's.
            return isInstalled(family) ? .family(family) : .system
        case .terminal:
            for family in terminalFamilies where isInstalled(family) {
                return .family(family)
            }
            return .monospacedSystem
        }
    }

    /// Whether this machine can draw `family`.
    ///
    /// Font lookup never fails outright: asking for a missing family hands
    /// back a substitute, so the returned font has to be checked against what
    /// was asked for instead of being trusted because it is non-nil.
    public static func isFamilyInstalled(_ family: String) -> Bool {
        resolvedFont(family: family, size: NSFont.systemFontSize, weight: .regular) != nil
    }

    /// What a piece of chrome text needs in order to keep its width.
    ///
    /// A monospaced request from a call site is about measurement, not style: a
    /// count that shifts as it changes, or a column of hashes that does not line
    /// up, is a worse result than not following the chrome family. So a family
    /// that draws proportionally is overridden for these callers rather than
    /// followed, and a family that is already fixed pitch satisfies them.
    public enum FixedPitchNeed: Sendable, Hashable {
        /// Nothing to keep; the chrome typeface decides.
        case none
        /// Digits share one advance, so numbers do not move as they change.
        case digits
        /// Every glyph shares one advance.
        case allGlyphs
    }

    /// The font for a piece of chrome text. Falls back to the system font if
    /// the family stops being drawable between resolution and drawing.
    public func appKitFont(
        size: CGFloat,
        weight: NSFont.Weight,
        needs: FixedPitchNeed = .none
    ) -> NSFont {
        let font = drawingFont(size: size, weight: weight)
        switch needs {
        case .none:
            return font
        case .digits:
            return font.isFixedPitch ? font : .monospacedDigitSystemFont(ofSize: size, weight: weight)
        case .allGlyphs:
            return font.isFixedPitch ? font : .monospacedSystemFont(ofSize: size, weight: weight)
        }
    }

    private func drawingFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        switch self {
        case .system:
            return .systemFont(ofSize: size, weight: weight)
        case .monospacedSystem:
            return .monospacedSystemFont(ofSize: size, weight: weight)
        case .family(let family):
            return Self.resolvedFont(family: family, size: size, weight: weight)
                ?? .systemFont(ofSize: size, weight: weight)
        }
    }

    /// The SwiftUI font for the same text. Built from the AppKit font on
    /// purpose: one resolution, two renderers.
    public func swiftUIFont(
        size: CGFloat,
        weight: NSFont.Weight,
        needs: FixedPitchNeed = .none
    ) -> Font {
        Font(appKitFont(size: size, weight: weight, needs: needs) as CTFont)
    }

    /// The SwiftUI font for a caller that has a `Font.Weight` in hand.
    ///
    /// SwiftUI and AppKit name the same nine weights, so this is a lookup
    /// rather than an approximation; an unrecognized weight falls back to
    /// regular, which is what `Font.system` would have drawn anyway.
    public func swiftUIFont(
        size: CGFloat,
        swiftUIWeight: Font.Weight,
        needs: FixedPitchNeed = .none
    ) -> Font {
        swiftUIFont(size: size, weight: Self.appKitWeight(matching: swiftUIWeight), needs: needs)
    }

    public static func appKitWeight(matching weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }

    /// `family` at `size` and `weight`, or `nil` when the machine substituted
    /// something else for it.
    ///
    /// A family shipped in one weight answers every weight with that weight, so
    /// the sidebar's resting and selected rows can come back identical under such
    /// a font. That is the family doing what it can rather than the weights being
    /// ignored, and it is why the selected row also carries a background.
    static func resolvedFont(family: String, size: CGFloat, weight: NSFont.Weight) -> NSFont? {
        let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: trimmed,
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
        ])
        guard let font = NSFont(descriptor: descriptor, size: size) else { return nil }
        // A config may name either the family ("SF Mono") or a specific face
        // ("SFMono-Regular"); both are legitimate Ghostty values.
        let matchesRequest = [font.familyName, font.fontName, font.displayName]
            .compactMap { $0 }
            .contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        return matchesRequest ? font : nil
    }
}
