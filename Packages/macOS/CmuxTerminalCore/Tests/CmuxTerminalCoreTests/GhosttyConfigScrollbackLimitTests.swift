import Testing
import CmuxTerminalCore

@Suite
struct GhosttyConfigScrollbackLimitTests {
    @Test func defaultScrollbackLimitMatchesCmuxManagedDefault() {
        let config = GhosttyConfig()

        #expect(config.scrollbackLimit == GhosttyScrollbackLimitDefault.bytes)
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

        config.parse(GhosttyScrollbackLimitDefault.configDirective)

        #expect(config.scrollbackLimit == GhosttyScrollbackLimitDefault.bytes)
    }

    @Test func parseInvalidScrollbackLimitLeavesDefaultUntouched() {
        var config = GhosttyConfig()

        config.parse("scrollback-limit = abc")
        #expect(config.scrollbackLimit == GhosttyScrollbackLimitDefault.bytes)
        config.parse("scrollback-limit = -1")
        #expect(config.scrollbackLimit == GhosttyScrollbackLimitDefault.bytes)
    }
}
