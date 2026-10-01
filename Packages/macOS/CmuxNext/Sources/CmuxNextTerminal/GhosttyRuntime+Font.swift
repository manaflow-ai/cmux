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

    /// Config lines for `font`. `font-family` is a list in Ghostty, so an
    /// empty value clears the config's families first. Values that could
    /// inject another line are dropped.
    public nonisolated static func fontOverrideLines(_ font: FontOverride) -> [String] {
        var lines: [String] = []
        if let family = font.family?.trimmingCharacters(in: .whitespaces), !family.isEmpty, family.count <= 120,
           family.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0 != "#" && $0 != "=" && $0 != "\"" }) {
            lines += ["font-family = \"\"", "font-family = \"\(family)\""]
        }
        if let size = font.size, size.isFinite, (4...96).contains(size) {
            lines.append("font-size = \(Int(size.rounded()))")
        }
        return lines
    }
}
