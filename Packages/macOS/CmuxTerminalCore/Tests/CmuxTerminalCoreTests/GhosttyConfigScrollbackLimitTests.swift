import Testing
import CmuxTerminalCore

@Suite
struct GhosttyConfigScrollbackLimitTests {
    @Test func defaultScrollbackLimitMatchesCmuxManagedDefault() {
        let config = GhosttyConfig()

        #expect(config.scrollbackLimit == GhosttyConfig.defaultScrollbackLimitBytes)
        #expect(config.scrollbackLimit == 4_000_000)
    }

    @Test func parseScrollbackLimitUserOverrideWins() {
        var config = GhosttyConfig()

        config.parse("scrollback-limit = 50000000")

        #expect(config.scrollbackLimit == 50_000_000)
    }

    @Test func parseScrollbackLimitAllowsUnderscoreDigitSeparators() {
        var config = GhosttyConfig()

        config.parse("scrollback-limit = 10_000_000")

        #expect(config.scrollbackLimit == 10_000_000)
    }

    @Test func parseScrollbackLimitDefaultDirectiveRoundTrips() {
        var config = GhosttyConfig()

        config.parse(GhosttyConfig.defaultScrollbackLimitConfigDirective)

        #expect(config.scrollbackLimit == GhosttyConfig.defaultScrollbackLimitBytes)
    }

    @Test func parseInvalidScrollbackLimitLeavesDefaultUntouched() {
        var config = GhosttyConfig()

        config.parse("scrollback-limit = abc")
        #expect(config.scrollbackLimit == GhosttyConfig.defaultScrollbackLimitBytes)
        config.parse("scrollback-limit = -1")
        #expect(config.scrollbackLimit == GhosttyConfig.defaultScrollbackLimitBytes)
    }
}
