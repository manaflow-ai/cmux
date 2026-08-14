import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Repaints a Highlightr `xcode` / `xcode-dark` attributed string with a
/// ``TokenPalette``.
///
/// Highlightr only loads bundled CSS. The adapter still tokenizes with those
/// stock themes, then this type swaps each known source hex for the matching
/// cmux role. Unknown colors are left unchanged.
public struct HighlightColorRemapper: Sendable {
    /// Destination palette.
    public let palette: TokenPalette
    /// Source hex key (`RRGGBB`) → role, taken from the Highlightr theme.
    public let sourceMap: [String: TokenRole]

    /// Creates a remapper for `theme`'s Highlightr source colors.
    ///
    /// - Parameter theme: Light or dark token theme.
    public init(theme: TokenTheme) {
        self.palette = theme.palette
        self.sourceMap = theme.sourceColorMap
    }

    /// Creates a remapper with an explicit source map. Used by tests.
    ///
    /// - Parameters:
    ///   - palette: Destination colors.
    ///   - sourceMap: Hex key (`RRGGBB`) → role.
    public init(palette: TokenPalette, sourceMap: [String: TokenRole]) {
        self.palette = palette
        self.sourceMap = sourceMap
    }

    /// Returns a copy of `attributed` with known source colors replaced.
    ///
    /// - Parameter attributed: Highlightr output.
    /// - Returns: The same string with cmux token colors.
    public func remap(_ attributed: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let full = NSRange(location: 0, length: mutable.length)
        guard full.length > 0 else { return mutable }
        mutable.enumerateAttribute(.foregroundColor, in: full, options: []) { value, range, _ in
            guard let value,
                  let hex = Self.hexKey(from: value),
                  let role = sourceMap[hex] else {
                return
            }
            mutable.addAttribute(
                .foregroundColor,
                value: Self.platformColor(palette.color(for: role)),
                range: range
            )
        }
        return mutable
    }

    /// Six-digit uppercase hex for a platform color attribute, if one can
    /// be read.
    ///
    /// - Parameter value: An `NSColor` or `UIColor` from Highlightr.
    /// - Returns: `RRGGBB`, or `nil` when the value is not a color.
    public static func hexKey(from value: Any) -> String? {
#if canImport(AppKit)
        guard let color = value as? NSColor else { return nil }
        // Highlightr bakes CSS hex as component RGB. Convert only when the
        // color is not already RGB so #FC5FA3 stays #FC5FA3.
        if color.type == .componentBased, color.colorSpace.colorSpaceModel == .rgb {
            return hexKey(
                red: color.redComponent,
                green: color.greenComponent,
                blue: color.blueComponent
            )
        }
        let rgb = color.usingColorSpace(.genericRGB) ?? color.usingColorSpace(.sRGB)
        guard let rgb else { return nil }
        return hexKey(
            red: rgb.redComponent,
            green: rgb.greenComponent,
            blue: rgb.blueComponent
        )
#elseif canImport(UIKit)
        guard let color = value as? UIColor else { return nil }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        return hexKey(red: red, green: green, blue: blue)
#else
        return nil
#endif
    }

    /// Platform color for a ``TokenColor`` in sRGB.
    ///
    /// - Parameter color: Palette swatch.
    /// - Returns: `NSColor` on macOS, `UIColor` on iOS.
    public static func platformColor(_ color: TokenColor) -> Any {
#if canImport(AppKit)
        return NSColor(
            srgbRed: CGFloat(color.red) / 255.0,
            green: CGFloat(color.green) / 255.0,
            blue: CGFloat(color.blue) / 255.0,
            alpha: 1
        )
#elseif canImport(UIKit)
        return UIColor(
            red: CGFloat(color.red) / 255.0,
            green: CGFloat(color.green) / 255.0,
            blue: CGFloat(color.blue) / 255.0,
            alpha: 1
        )
#else
        return color.hexString
#endif
    }

    /// Rounds unit RGB components to a six-digit hex key.
    ///
    /// - Parameters:
    ///   - red: Red, 0...1.
    ///   - green: Green, 0...1.
    ///   - blue: Blue, 0...1.
    /// - Returns: `RRGGBB`.
    public static func hexKey(red: CGFloat, green: CGFloat, blue: CGFloat) -> String {
        let clamp: (CGFloat) -> Int = { value in
            let scaled = (value * 255.0).rounded()
            return min(255, max(0, Int(scaled)))
        }
        return String(format: "%02X%02X%02X", clamp(red), clamp(green), clamp(blue))
    }
}
