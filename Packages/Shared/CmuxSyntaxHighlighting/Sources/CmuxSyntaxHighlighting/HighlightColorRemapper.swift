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
    /// Collision-free 24-bit RGB lookup derived from ``sourceMap``.
    private let packedSourceMap: [UInt32: TokenRole]
    private let colorPacking: HighlightColorPacking

    /// Creates a remapper for `theme`'s Highlightr source colors.
    ///
    /// - Parameter theme: Light or dark token theme.
    public init(theme: TokenTheme) {
        self.init(palette: theme.palette, sourceMap: theme.sourceColorMap)
    }

    /// Creates a remapper with an explicit source map.
    ///
    /// - Parameters:
    ///   - palette: Destination colors.
    ///   - sourceMap: Hex key (`RRGGBB`) → role.
    public init(palette: TokenPalette, sourceMap: [String: TokenRole]) {
        self.palette = palette
        self.sourceMap = sourceMap
        let colorPacking = HighlightColorPacking()
        self.colorPacking = colorPacking
        self.packedSourceMap = sourceMap.reduce(into: [:]) { result, entry in
            guard let key = colorPacking.packedRGBKey(fromHexKey: entry.key) else { return }
            result[key] = entry.value
        }
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
                  let key = colorPacking.packedRGBKey(from: value),
                  let role = packedSourceMap[key] else {
                return
            }
            mutable.addAttribute(
                .foregroundColor,
                value: colorPacking.platformColor(palette.color(for: role)),
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
    public func hexKey(from value: Any) -> String? {
        guard let key = colorPacking.packedRGBKey(from: value) else { return nil }
        return colorPacking.hexKey(fromPacked: key)
    }

    /// Platform color for a ``TokenColor`` in sRGB.
    ///
    /// - Parameter color: Palette swatch.
    /// - Returns: `NSColor` on macOS, `UIColor` on iOS.
    func platformColor(_ color: TokenColor) -> Any {
        colorPacking.platformColor(color)
    }

    /// Rounds unit RGB components to a six-digit hex key.
    ///
    /// - Parameters:
    ///   - red: Red, 0...1.
    ///   - green: Green, 0...1.
    ///   - blue: Blue, 0...1.
    /// - Returns: `RRGGBB`.
    public func hexKey(red: CGFloat, green: CGFloat, blue: CGFloat) -> String {
        colorPacking.hexKey(
            fromPacked: colorPacking.packedRGBKey(red: red, green: green, blue: blue)
        )
    }

}
