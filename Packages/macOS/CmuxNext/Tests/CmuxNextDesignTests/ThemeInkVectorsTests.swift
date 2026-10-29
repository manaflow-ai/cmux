import CmuxTheme
@testable import CmuxNextDesign
import Foundation
import Testing

/// `schemas/theme/theme-ink-vectors.json` is what Swift derives for every bundled theme: its text
/// inks (`ThemeTokens.inks`) and its popup surface (`opaqueOverlayFill` at the shipped lift). The
/// spec's `derive_theme_tokens.py` writes it; the other ports (Rust `cmux-theme-tokens`, the web
/// gallery and the agent pane harness) replay it once they take #23441's rules. A Swift change to either rule fails here until the change is
/// ported to `derive_theme_tokens.py` and the file regenerated with `--theme-ink-vectors`; the
/// other ports then fail until they follow.
@MainActor @Suite struct ThemeInkVectorsTests {
    static let path = CardNeverOpaqueTests.repoRoot.appending(path: "schemas/theme/theme-ink-vectors.json")

    /// `#RRGGBB`, each channel rounded half away from zero, as the file writes it.
    static func hex(_ color: ThemeRGB) -> String {
        "#" + [color.red, color.green, color.blue].map { channel in
            let text = String(Int((channel * 255).rounded()), radix: 16, uppercase: true)
            return text.count < 2 ? "0" + text : text
        }.joined()
    }

    /// One theme's row as flat `field: value` text, the shape both sides compare in.
    static func row(_ theme: CardNeverOpaqueTests.BundledTheme) -> [String: String] {
        let tokens = theme.tokens
        var row = [
            "background": hex(theme.input.background),
            "foreground": hex(theme.input.foreground),
            "isDark": String(tokens.isDark),
            "textPrimary": hex(tokens.textPrimary),
            "textSecondary": hex(tokens.textSecondary),
            "textTertiary": hex(tokens.textTertiary),
            "opaqueOverlayFill": hex(tokens.opaqueOverlayFill(lift: CardNeverOpaqueTests.lift)),
        ]
        // The palette reaches the inks only through the theme's own accent (`AppTheme`).
        if let accent = theme.input.accentColor {
            row["accentColor"] = hex(accent)
            row["palette"] = theme.input.palette.map(hex).joined(separator: " ")
        }
        return row
    }

    /// The file's rows by theme (`ghostty/themes/Grass`), in the same flat shape.
    static func fileRows() throws -> (lift: Double?, rows: [String: [String: String]]) {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
        var rows: [String: [String: String]] = [:]
        for case let item as [String: Any] in object?["cases"] as? [Any] ?? [] {
            guard let theme = item["theme"] as? String else { continue }
            var row: [String: String] = [:]
            for (key, value) in item where key != "theme" && key != "input" {
                row[key] = (value as? Bool).map { String($0) } ?? value as? String
            }
            for (key, value) in item["input"] as? [String: Any] ?? [:] {
                row[key] = (value as? [String])?.joined(separator: " ") ?? value as? String
            }
            rows[theme] = row
        }
        return (object?["lift"] as? Double, rows)
    }

    @Test func theInkVectorsAreSwiftsOutputForEveryBundledTheme() throws {
        let themes = try CardNeverOpaqueTests.bundledThemes()
        #expect(themes.count > 500, "read only \(themes.count) bundled themes")
        var swift: [String: [String: String]] = [:]
        for theme in themes {
            swift[theme.folder.replacingOccurrences(of: "Resources/", with: "") + "/" + theme.name] = Self.row(theme)
        }
        let file = try Self.fileRows()
        #expect(file.lift == CardNeverOpaqueTests.lift, "the file's lift \(String(describing: file.lift))")
        var differences: [String] = []
        for name in Set(swift.keys).union(file.rows.keys).sorted() where swift[name] != file.rows[name] {
            differences.append("\(name): file \(file.rows[name]?.description ?? "none"), Swift \(swift[name]?.description ?? "none")")
        }
        #expect(differences.isEmpty, """
            \(Self.path.path) differs from Swift in \(differences.count) themes; port the change to \
            derive_theme_tokens.py and run it with --theme-ink-vectors:
            \(differences.joined(separator: "\n"))
            """)
    }
}
