import Foundation

/// cmux's own terminal font (`terminal.fontFamily`, `terminal.fontSize` in
/// cmux.json, written by onboarding), loaded after the Ghostty config files
/// like `themeOverride`. Nil keeps the config's value. Set, then call
/// `reloadConfig()`.
extension GhosttyRuntime {
    public nonisolated struct FontOverride: Equatable, Sendable {
        public var family: String?
        public var size: Double?

        public init(family: String? = nil, size: Double? = nil) {
            self.family = family
            self.size = size
        }
    }

    public static var fontOverride = FontOverride()

    /// Optional faces used after the person's chosen face. Ghostty ignores a
    /// family that is not installed, so these keep a config portable while
    /// giving Nerd Font private-use and CJK glyphs a monospace fallback when
    /// the face is available.
    public nonisolated static let knownFallbackFamilies = [
        "Symbols Nerd Font Mono",
        "Noto Sans Mono CJK JP",
    ]

    /// Config lines for `font`. `font-family` is a list in Ghostty, so an
    /// empty value clears the config's families first. The selected family is
    /// first, then the loaded config's fallback chain and known optional faces.
    /// Values are quoted and escaped so valid family names containing `#`, `=` or quotes stay
    /// in the fallback chain; control characters that could inject another line are dropped.
    public nonisolated static func fontOverrideLines(_ font: FontOverride,
                                                     fallbackFamilies: [String] = []) -> [String] {
        var lines: [String] = []
        if let family = quotedFamily(font.family) {
            var families = [family] + fallbackFamilies + knownFallbackFamilies
            var seen = Set<String>()
            families = families.compactMap { value in
                guard let value = quotedFamily(value) else { return nil }
                let key = value.lowercased()
                return seen.insert(key).inserted ? value : nil
            }
            lines.append("font-family = \"\"")
            lines += families.map { "font-family = \"\(escapedFamily($0))\"" }
        }
        if let size = font.size, size.isFinite, (4...96).contains(size) {
            // Ghostty takes fractional points; at most two decimals.
            let points = (size * 100).rounded() / 100
            lines.append(points == points.rounded() ? "font-size = \(Int(points))" : "font-size = \(points)")
        }
        return lines
    }

    private nonisolated static func quotedFamily(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty, value.count <= 120,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }

    private nonisolated static func escapedFamily(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
