public import AppKit
import CoreText
public import SwiftUI

/// A normalized, optional font-family override shared by AppKit and SwiftUI.
/// An empty value means that the platform's system font should be used.
public struct CmuxFontFamily: Equatable, Hashable, Sendable {
    public let name: String

    public init?(_ rawValue: String?) {
        guard let normalized = Self.normalizedName(rawValue) else { return nil }
        name = normalized
    }

    public init?(rawValue: String) {
        self.init(rawValue)
    }

    public static func normalizedName(_ rawValue: String?) -> String? {
        rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private final class CmuxCachedFont {
    let font: NSFont?

    init(_ font: NSFont?) {
        self.font = font
    }
}

/// NSCache synchronizes access internally; its references and cached font entries are immutable.
private final class CmuxFontResolverCache: @unchecked Sendable {
    let familyAvailability = NSCache<NSString, NSString>()
    let familyFonts = NSCache<NSString, CmuxCachedFont>()

    init() {
        familyAvailability.countLimit = 128
        familyFonts.countLimit = 512
    }
}

/// Resolves one family override consistently for native and SwiftUI sidebar
/// renderers. Invalid names deliberately return the platform fallback.
public enum CmuxFontResolver {
    private static let cache = CmuxFontResolverCache()

    public static func appKitFont(
        family: String?,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        monospaced: Bool = false,
        monospacedDigits: Bool = false
    ) -> NSFont {
        let fallback = monospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : monospacedDigits
                ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                : NSFont.systemFont(ofSize: size, weight: weight)
        guard let family = CmuxFontFamily(family),
              let resolved = familyFont(
                  family,
                  size: size,
                  weight: weight,
                  monospacedDigits: monospacedDigits
              ) else {
            return fallback
        }
        return resolved
    }

    public static func swiftUIFont(
        family: String?,
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        monospacedDigit: Bool = false
    ) -> Font {
        var font: Font
        if let family = CmuxFontFamily(family),
           let resolved = familyFont(family, size: size, weight: .regular) {
            font = Font.custom(resolved.fontName, size: size).weight(weight)
        } else {
            font = Font.system(size: size, weight: weight, design: design)
        }
        if monospacedDigit {
            font = font.monospacedDigit()
        }
        return font
    }

    private static func familyFont(
        _ family: CmuxFontFamily?,
        size: CGFloat,
        weight: NSFont.Weight,
        monospacedDigits: Bool = false
    ) -> NSFont? {
        guard let family else { return nil }
        let familyKey = family.name.lowercased() as NSString
        let canonicalFamily: String
        if let cachedFamily = cache.familyAvailability.object(forKey: familyKey) {
            canonicalFamily = cachedFamily as String
        } else {
            canonicalFamily = NSFontManager.shared.availableFontFamilies.first {
                $0.caseInsensitiveCompare(family.name) == .orderedSame
            } ?? ""
            cache.familyAvailability.setObject(canonicalFamily as NSString, forKey: familyKey)
        }
        guard !canonicalFamily.isEmpty else { return nil }

        let fontKey = "\(familyKey)|\(size)|\(weight.rawValue)|\(monospacedDigits)" as NSString
        if let cached = cache.familyFonts.object(forKey: fontKey) {
            return cached.font
        }
        let source = NSFont.systemFont(ofSize: size, weight: weight)
        let familyResolved = NSFontManager.shared.convert(source, toFamily: canonicalFamily)
        let resolved: NSFont?
        if familyResolved.familyName?.caseInsensitiveCompare(family.name) != .orderedSame {
            resolved = nil
        } else if monospacedDigits {
            resolved = fontWithMonospacedDigits(familyResolved, size: size)
        } else {
            resolved = familyResolved
        }
        cache.familyFonts.setObject(CmuxCachedFont(resolved), forKey: fontKey)
        return resolved
    }

    private static func fontWithMonospacedDigits(_ font: NSFont, size: CGFloat) -> NSFont {
        let descriptor = font.fontDescriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]],
        ])
        return NSFont(descriptor: descriptor, size: size) ?? font
    }
}
