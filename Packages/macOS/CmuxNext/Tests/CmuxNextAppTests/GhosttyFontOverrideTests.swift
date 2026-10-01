import CmuxNextTerminal
import Testing

@Suite struct GhosttyFontOverrideTests {
    @Test func familyReplacesTheListAndSizeRounds() {
        let lines = GhosttyRuntime.fontOverrideLines(.init(family: "JetBrains Mono", size: 13.4))
        #expect(lines == ["font-family = \"\"", "font-family = \"JetBrains Mono\"", "font-size = 13"])
    }

    @Test func refusesInjectionAndOutOfRange() {
        #expect(GhosttyRuntime.fontOverrideLines(.init(family: "A\ntheme = x", size: 500)).isEmpty)
        #expect(GhosttyRuntime.fontOverrideLines(.init(family: "A=B")).isEmpty)
        #expect(GhosttyRuntime.fontOverrideLines(.init()).isEmpty)
    }
}
