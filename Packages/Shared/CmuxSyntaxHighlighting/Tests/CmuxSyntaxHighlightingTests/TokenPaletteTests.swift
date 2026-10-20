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
}
