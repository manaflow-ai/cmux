import Foundation

/// Renders terminal palettes as an OpenCode theme.
///
/// OpenCode reads `~/.config/opencode/themes/<slug>.json` with `$schema`,
/// reusable `defs` and `theme` tokens; see opencode.ai/docs/themes. A token
/// value may be a `{ "dark": ..., "light": ... }` pair, so a Ghostty
/// light/dark theme pair becomes one file that follows OpenCode's mode.
///
/// The palette goes into `defs` as `bg`, `fg` and ANSI names (`red`,
/// `brightBlue`; with a pair, `darkRed` and `lightRed`) and tokens refer to them, so the file reads
/// like the terminal theme it came from. The mapping follows OpenCode's own
/// terminal-derived `system` theme, with the exact palette instead of ANSI
/// indexes:
/// - `background` is `"none"`, so OpenCode draws on the terminal's own
///   background, including any background opacity or image.
/// - Accents: primary blue, secondary magenta, accent bright magenta,
///   info cyan; status colors red, yellow and green.
/// - Panels, elements and borders are background-to-foreground blends.
/// - Diff backgrounds are the background with a little red or green mixed in.
public struct OpenCodeThemeRenderer: Sendable {
    /// The JSON schema OpenCode theme files declare.
    public static let schemaURL = "https://opencode.ai/theme.json"

    /// Creates the renderer. It holds no state.
    public init() {}

    /// Renders the theme file.
    /// - Parameter appearances: One palette, or a light/dark pair.
    /// - Returns: The theme file's JSON, ending in a newline.
    public func render(appearances: AgentThemeAppearances) -> String {
        let variants: [(prefix: String, palette: TerminalPalette)]
        switch appearances {
        case .single(let palette):
            variants = [("", palette)]
        case .pair(let light, let dark):
            variants = [("dark", dark), ("light", light)]
        }

        var defs: [(String, AgentThemeJSON)] = []
        for variant in variants {
            for (name, color) in Self.defNames(for: variant.palette) {
                defs.append((Self.defName(name, prefix: variant.prefix), .string(color.hexString)))
            }
        }

        let tokens: [(String, AgentThemeJSON)] = Self.tokens.map { name, value in
            switch value {
            case .none:
                return (name, .string("none"))
            case .token(let other):
                return (name, .string(other))
            case .def(let defName):
                return (name, Self.value(variants: variants) { prefix, _ in
                    Self.defName(defName, prefix: prefix)
                })
            case .blend(let blend):
                return (name, Self.value(variants: variants) { _, palette in
                    blend(palette).hexString
                })
            }
        }

        return AgentThemeJSON.object([
            ("$schema", .string(Self.schemaURL)),
            ("defs", .object(defs, inline: false)),
            ("theme", .object(tokens, inline: false)),
        ], inline: false).rendered()
    }

    /// A token's value: a def, a blend computed from the palette, another
    /// token, or the terminal's own color.
    private enum TokenValue: Sendable {
        case def(String)
        case blend(@Sendable (TerminalPalette) -> GhosttyThemeRGB)
        case token(String)
        case none
    }

    private static let ansiNames = [
        "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
        "brightBlack", "brightRed", "brightGreen", "brightYellow",
        "brightBlue", "brightMagenta", "brightCyan", "brightWhite",
    ]

    private static func defNames(for palette: TerminalPalette) -> [(String, GhosttyThemeRGB)] {
        [("bg", palette.background), ("fg", palette.foreground)]
            + zip(ansiNames, palette.ansi).map { ($0, $1) }
    }

    private static func defName(_ name: String, prefix: String) -> String {
        guard !prefix.isEmpty, let first = name.first else { return name }
        return prefix + first.uppercased() + String(name.dropFirst())
    }

    private static func value(
        variants: [(prefix: String, palette: TerminalPalette)],
        _ resolve: (String, TerminalPalette) -> String
    ) -> AgentThemeJSON {
        if variants.count == 1, let only = variants.first {
            return .string(resolve(only.prefix, only.palette))
        }
        return .object(variants.map { ($0.prefix, .string(resolve($0.prefix, $0.palette))) }, inline: true)
    }

    private static func gray(_ foregroundShare: Double) -> TokenValue {
        .blend { $0.background.mixed(toward: $0.foreground, amount: foregroundShare) }
    }

    private static func tint(_ ansiIndex: Int, over base: @escaping @Sendable (TerminalPalette) -> GhosttyThemeRGB) -> TokenValue {
        .blend { palette in
            base(palette).mixed(toward: palette.ansi[ansiIndex], amount: palette.isDark ? 0.22 : 0.14)
        }
    }

    private static let panel: @Sendable (TerminalPalette) -> GhosttyThemeRGB = {
        $0.background.mixed(toward: $0.foreground, amount: 0.05)
    }

    private static let tokens: [(String, TokenValue)] = [
        ("primary", .def("blue")),
        ("secondary", .def("magenta")),
        ("accent", .def("brightMagenta")),
        ("error", .def("red")),
        ("warning", .def("yellow")),
        ("success", .def("green")),
        ("info", .def("cyan")),
        ("text", .def("fg")),
        ("textMuted", gray(0.55)),
        ("selectedListItemText", .def("bg")),
        ("background", .none),
        ("backgroundPanel", .blend(panel)),
        ("backgroundElement", gray(0.09)),
        ("backgroundMenu", .token("backgroundElement")),
        ("border", gray(0.25)),
        ("borderActive", gray(0.45)),
        ("borderSubtle", gray(0.15)),
        ("diffAdded", .def("green")),
        ("diffRemoved", .def("red")),
        ("diffContext", .token("textMuted")),
        ("diffHunkHeader", .def("cyan")),
        ("diffHighlightAdded", .def("brightGreen")),
        ("diffHighlightRemoved", .def("brightRed")),
        ("diffAddedBg", tint(2, over: { $0.background })),
        ("diffRemovedBg", tint(1, over: { $0.background })),
        ("diffContextBg", .token("backgroundPanel")),
        ("diffLineNumber", .token("textMuted")),
        ("diffAddedLineNumberBg", tint(2, over: panel)),
        ("diffRemovedLineNumberBg", tint(1, over: panel)),
        ("markdownText", .def("fg")),
        ("markdownHeading", .def("magenta")),
        ("markdownLink", .def("blue")),
        ("markdownLinkText", .def("cyan")),
        ("markdownCode", .def("green")),
        ("markdownBlockQuote", .def("yellow")),
        ("markdownEmph", .def("yellow")),
        ("markdownStrong", .def("fg")),
        ("markdownHorizontalRule", .token("border")),
        ("markdownListItem", .def("blue")),
        ("markdownListEnumeration", .def("cyan")),
        ("markdownImage", .def("blue")),
        ("markdownImageText", .def("cyan")),
        ("markdownCodeBlock", .def("fg")),
        ("syntaxComment", .token("textMuted")),
        ("syntaxKeyword", .def("magenta")),
        ("syntaxFunction", .def("blue")),
        ("syntaxVariable", .def("fg")),
        ("syntaxString", .def("green")),
        ("syntaxNumber", .def("yellow")),
        ("syntaxType", .def("cyan")),
        ("syntaxOperator", .def("cyan")),
        ("syntaxPunctuation", .def("fg")),
    ]
}
