import CmuxTerminalCore
import Testing

@Suite
struct ScrollbackLimitConfigTests {
    @Test func defaultMatchesGhosttyCompressedScrollbackLimit() {
        let config = GhosttyConfig()

        #expect(config.scrollbackLimit == 50_000_000)
    }

    @Test func explicitLimitOverridesDefault() {
        var config = GhosttyConfig()

        config.parse("scrollback-limit = 10_000_000")

        #expect(config.scrollbackLimit == 10_000_000)
    }
}
