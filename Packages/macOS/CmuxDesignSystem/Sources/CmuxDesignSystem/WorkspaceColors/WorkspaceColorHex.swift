public import AppKit
import Foundation

/// A normalized six-digit sRGB hex color used by workspace color tokens.
public struct WorkspaceColorHex: RawRepresentable, Codable, Hashable, Sendable {
    /// The normalized `#RRGGBB` value.
    public let rawValue: String

    /// Creates a normalized workspace color hex value.
    ///
    /// - Parameter rawValue: A six-digit hex color with or without a leading `#`.
    public init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let body = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard body.count == 6 else { return nil }
        guard UInt64(body, radix: 16) != nil else { return nil }
        self.rawValue = "#" + body.uppercased()
    }

    /// Creates a normalized workspace color hex value.
    ///
    /// - Parameter rawValue: A six-digit hex color with or without a leading `#`.
    public init?(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    /// The color represented in sRGB.
    public var nsColor: NSColor {
        let body = String(rawValue.dropFirst())
        let rgb = UInt64(body, radix: 16) ?? 0
        return NSColor(
            srgbRed: CGFloat((rgb & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgb & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgb & 0x0000FF) / 255.0,
            alpha: 1.0
        )
    }

    /// Returns the display color for the requested appearance.
    ///
    /// Workspace tab colors are boosted in dark appearances so darker palette
    /// tokens remain legible as indicators and row fills.
    ///
    /// - Parameters:
    ///   - colorScheme: The appearance family to resolve against.
    ///   - forceBright: Whether to apply the dark-appearance boost even in light appearances.
    /// - Returns: The resolved display color.
    public func displayNSColor(
        colorScheme: WorkspaceColorScheme,
        forceBright: Bool = false
    ) -> NSColor {
        if forceBright || colorScheme == .dark {
            return brightenedForDarkAppearance(nsColor)
        }
        return nsColor
    }

    private func brightenedForDarkAppearance(_ color: NSColor) -> NSColor {
        let rgbColor = color.usingColorSpace(.sRGB) ?? color
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgbColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let boostedBrightness = min(1, max(brightness, 0.62) + ((1 - brightness) * 0.28))
        let boostedSaturation: CGFloat
        if saturation <= 0.08 {
            boostedSaturation = saturation
        } else {
            boostedSaturation = min(1, saturation + ((1 - saturation) * 0.12))
        }

        return NSColor(
            hue: hue,
            saturation: boostedSaturation,
            brightness: boostedBrightness,
            alpha: alpha
        )
    }
}
