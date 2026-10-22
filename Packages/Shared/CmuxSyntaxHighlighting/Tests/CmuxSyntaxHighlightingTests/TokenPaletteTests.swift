import CmuxSyntaxHighlighting
import Testing

@Suite("Cmux token palette")
struct TokenPaletteTests {
    @Test("Dark keywords use published product blue")
    func darkKeywordIsProductBlue() {
        #expect(TokenPalette.cmuxDark.keyword.hexString == "#0091FF")
        #expect(TokenTheme.dark.palette.keyword == TokenPalette.cmuxDark.keyword)
    }

    @Test("Light keywords use product-blue-on-foreground")
    func lightKeywordIsReadableProductBlue() {
        #expect(TokenPalette.cmuxLight.keyword.hexString == "#006DC1")
        #expect(TokenPalette.cmuxLight.type.hexString == "#0073D9")
        #expect(TokenPalette.cmuxLight.regexp.hexString == "#0088FF")
        #expect(TokenTheme.light.palette.keyword == TokenPalette.cmuxLight.keyword)
    }

    @Test("Surfaces keep brand neutrals")
    func neutralsMatchMarketingTokens() {
        #expect(TokenPalette.cmuxDark.foreground.hexString == "#EDEDED")
        #expect(TokenPalette.cmuxLight.foreground.hexString == "#171717")
        #expect(TokenPalette.cmuxLight.comment.hexString == "#737373")
    }

    @Test("Parses hash and bare hex")
    func tokenColorParsesHex() throws {
        let hashed = try #require(TokenColor(hex: "#0091ff"))
        let bare = try #require(TokenColor(hex: "0091FF"))
        #expect(hashed == bare)
        #expect(hashed.hexKey == "0091FF")
        #expect(TokenColor(hex: "nope") == nil)
    }

    @Test("Ghostty ANSI colors drive semantic token roles")
    func ghosttyAnsiColorsDriveSemanticTokenRoles() throws {
        let red = try #require(TokenColor(hex: "#110000"))
        let green = try #require(TokenColor(hex: "#001100"))
        let yellow = try #require(TokenColor(hex: "#111100"))
        let blue = try #require(TokenColor(hex: "#000011"))
        let magenta = try #require(TokenColor(hex: "#110011"))
        let cyan = try #require(TokenColor(hex: "#001111"))
        let black = try #require(TokenColor(hex: "#010101"))
        let white = try #require(TokenColor(hex: "#FEFEFE"))
        let foreground = try #require(TokenColor(hex: "#ABCDEF"))
        let ansi: [Int: TokenColor] = [
            1: red,
            2: green,
            3: yellow,
            4: blue,
            5: magenta,
            6: cyan,
            7: white,
            8: black,
        ]

        let palette = TokenPalette(
            ansiPalette: ansi,
            foreground: foreground,
            fallback: .cmuxDark
        )
        let theme = TokenTheme(base: .dark, palette: palette)

        #expect(theme.palette.foreground == foreground)
        #expect(theme.palette.keyword == red)
        #expect(theme.palette.string == cyan)
        #expect(theme.palette.comment == black)
        #expect(theme.palette.type == magenta)
        #expect(theme.palette.number == yellow)
        #expect(theme.palette.attribute == blue)
        #expect(theme.palette.variable == foreground)
        #expect(theme.palette.regexp == green)
    }
}
