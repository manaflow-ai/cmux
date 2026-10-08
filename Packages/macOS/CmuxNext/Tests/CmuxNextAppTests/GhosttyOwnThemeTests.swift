@testable import CmuxNextApp
import Testing

@Suite struct GhosttyOwnThemeTests {
    @Test func themeOrColorsCountCommentsDoNot() {
        #expect(GhosttyOwnTheme.setsLook("font-size = 13\ntheme = Nord\n"))
        #expect(GhosttyOwnTheme.setsLook("background = 101010"))
        #expect(!GhosttyOwnTheme.setsLook("# theme = Nord\nfont-family = Menlo\ntheme =\n"))
    }
}
