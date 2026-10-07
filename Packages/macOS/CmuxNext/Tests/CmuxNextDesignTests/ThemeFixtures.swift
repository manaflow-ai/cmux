@testable import CmuxNextDesign

/// Real Ghostty themes (values from Ghostty.app's bundled theme files).
nonisolated enum ThemeFixtures {
    static func input(bg: UInt32, fg: UInt32, palette: [UInt32], selection: UInt32? = nil) -> ThemeInput {
        ThemeInput(
            background: ThemeRGB(hex: bg),
            foreground: ThemeRGB(hex: fg),
            palette: palette.map { ThemeRGB(hex: $0) },
            selectionBackground: selection.map { ThemeRGB(hex: $0) }
        )
    }

    /// The user's current theme.
    static let monokaiClassic = input(bg: 0x272822, fg: 0xFDFFF1, palette: [
        0x272822, 0xF92672, 0xA6E22E, 0xE6DB74, 0xFD971F, 0xAE81FF, 0x66D9EF, 0xFDFFF1,
        0x6E7066, 0xF92672, 0xA6E22E, 0xE6DB74, 0xFD971F, 0xAE81FF, 0x66D9EF, 0xFDFFF1,
    ], selection: 0x57584F)

    static let catppuccinMocha = input(bg: 0x1E1E2E, fg: 0xCDD6F4, palette: [
        0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8,
        0x585B70, 0xF37799, 0x89D88B, 0xEBD391, 0x74A8FC, 0xF2AEDE, 0x6BD7CA, 0xBAC2DE,
    ])

    static let gruvboxDark = input(bg: 0x282828, fg: 0xEBDBB2, palette: [
        0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
        0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2,
    ])

    static let githubLight = input(bg: 0xFFFFFF, fg: 0x1F2328, palette: [
        0x24292F, 0xCF222E, 0x116329, 0x4D2D00, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
        0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F,
    ])

    /// A deliberately washed-out theme: the derivation must repair contrast.
    static let lowContrast = input(bg: 0x3A3A3A, fg: 0x6A6A6A, palette: [])

    static let all: [(String, ThemeInput)] = [
        ("Monokai Classic", monokaiClassic),
        ("Catppuccin Mocha", catppuccinMocha),
        ("Gruvbox Dark", gruvboxDark),
        ("GitHub Light Default", githubLight),
        ("low contrast", lowContrast),
    ]
}
