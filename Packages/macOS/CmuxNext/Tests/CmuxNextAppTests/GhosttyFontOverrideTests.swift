import CmuxNextTerminal
import Testing

@Suite struct GhosttyFontOverrideTests {
    /// Ghostty accepts fractional points, so the override keeps them
    /// (R92: 13.5 used to become 14).
    @Test func familyReplacesTheListAndSizeKeepsFractions() {
        let lines = GhosttyRuntime.fontOverrideLines(.init(family: "JetBrains Mono", size: 13.5))
        #expect(lines == ["font-family = \"\"", "font-family = \"JetBrains Mono\"", "font-size = 13.5"])
        #expect(GhosttyRuntime.fontOverrideLines(.init(size: 14)) == ["font-size = 14"])
        #expect(GhosttyRuntime.fontOverrideLines(.init(size: 12.25)) == ["font-size = 12.25"])
    }

    @Test func refusesInjectionAndOutOfRange() {
        #expect(GhosttyRuntime.fontOverrideLines(.init(family: "A\ntheme = x", size: 500)).isEmpty)
        #expect(GhosttyRuntime.fontOverrideLines(.init(family: "A=B")).isEmpty)
        #expect(GhosttyRuntime.fontOverrideLines(.init()).isEmpty)
    }
}
