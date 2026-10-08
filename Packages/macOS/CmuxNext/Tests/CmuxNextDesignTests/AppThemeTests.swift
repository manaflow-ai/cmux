import CmuxTheme
import Foundation
import Testing

/// The Swift port of the app-theme contract (`CmuxTheme.AppTheme`) against the web module it
/// mirrors: the same tokens for the vectors the web module exported
/// (`schemas/theme/app-theme-vectors.json`), and every contract pair met on every bundled theme.
@Suite struct AppThemeTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    struct Vector: Decodable {
        struct Input: Decodable {
            let background: String
            let foreground: String
            let palette: [String?]
        }

        let name: String
        let input: Input
        let isDark: Bool
        let accentSource: Int?
        let tokens: [String: String]
    }

    struct Vectors: Decodable {
        let tokens: [String: String]
        let cases: [Vector]
    }

    static func vectors() throws -> Vectors {
        let url = repoRoot.appending(path: "schemas/theme/app-theme-vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    @Test func tokenNamesAndVariablesMatchTheWebContract() throws {
        let web = try Self.vectors().tokens
        let swift = Dictionary(uniqueKeysWithValues: AppTheme.Token.allCases.map { ($0.rawValue, $0.variable) })
        #expect(swift == web)
    }

    @Test func derivesTheWebModulesTokens() throws {
        let vectors = try Self.vectors()
        #expect(vectors.cases.count > 50)
        var mismatches: [String] = []
        for vector in vectors.cases {
            let app = AppTheme.derive(
                background: try #require(ThemeRGB(cssHex: vector.input.background)),
                foreground: try #require(ThemeRGB(cssHex: vector.input.foreground)),
                palette: vector.input.palette.map { $0.flatMap(ThemeRGB.init(cssHex:)) }
            )
            if app.isDark != vector.isDark || app.accentSource != vector.accentSource {
                mismatches.append("\(vector.name): isDark/accentSource")
            }
            for token in AppTheme.Token.allCases where AppTheme.hex(app[token]) != vector.tokens[token.rawValue] {
                mismatches.append("\(vector.name).\(token.rawValue): \(AppTheme.hex(app[token])) != \(vector.tokens[token.rawValue] ?? "-")")
            }
        }
        #expect(mismatches == [])
    }

    /// The no-blue rule: the accent (on toggles, selection, focus ring) is a neutral from the
    /// theme's foreground, never the palette's blue ANSI 4, in a dark and a light theme.
    @Test(arguments: [(0x282C34, 0xFFFFFF), (0xFFFFFF, 0x1D1F21)])
    func theDefaultPaletteGivesANeutralAccent(_ colors: (background: UInt32, foreground: UInt32)) {
        let app = AppTheme.derive(background: ThemeRGB(hex: colors.background),
                                  foreground: ThemeRGB(hex: colors.foreground), palette: [ThemeRGB?]())
        for token in [AppTheme.Token.accent, .focusRing, .accentText] {
            let color = app[token]
            let spread = max(color.red, color.green, color.blue) - min(color.red, color.green, color.blue)
            #expect(spread < 0.03, "\(token) is \(AppTheme.hex(color)), not neutral")
        }
        #expect(app.failures.isEmpty)
    }

    @Test func everyBundledThemeMeetsEveryContractPair() throws {
        let folder = Self.repoRoot.appending(path: "Resources/ghostty/themes")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }
        #expect(names.count >= 617)
        var failures: [String] = []
        for name in names {
            let text = try String(contentsOf: folder.appending(path: name), encoding: .utf8)
            let colors = try #require(ThemeFileColors(name: name, themeFile: text), "\(name) has no colors")
            for pair in colors.appTheme.failures { failures.append("\(name): \(pair.token) on \(pair.on)") }
        }
        #expect(failures == [])
    }

    @Test func aThemeFileReadsLikeTheWebParser() throws {
        let colors = try #require(ThemeFileColors(name: "Sample", themeFile: """
        # comment
        palette = 0=#000000
        palette = 4=#3366ff
        palette = 99=#ffffff
        background = #1E1E1E
        foreground = ffffff
        selection-background = #3f638b
        cursor-color = #ff0000
        """))
        #expect(AppTheme.hex(colors.background) == "#1e1e1e")
        #expect(colors.palette.count == 16)
        #expect(colors.palette[4].map(AppTheme.hex) == "#3366ff")
        #expect(colors.palette[1] == nil)
        #expect(colors.cursorColor.map(AppTheme.hex) == "#ff0000")
        #expect(colors.selectionBackground.map(AppTheme.hex) == "#3f638b")
        #expect(ThemeFileColors(name: "Empty", themeFile: "palette = 0=#000000") == nil)
    }
}
