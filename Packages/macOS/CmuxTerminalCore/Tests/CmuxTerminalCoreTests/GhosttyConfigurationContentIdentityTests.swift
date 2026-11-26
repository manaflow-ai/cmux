internal import GhosttyKit
import Testing
@testable import CmuxTerminalCore

@Suite("Ghostty configuration content identity")
struct GhosttyConfigurationContentIdentityTests {
    @Test
    func equalEffectiveConfigurationsHaveEqualIdentities() throws {
        let first = try #require(ghostty_config_new())
        let second = try #require(ghostty_config_new())
        defer {
            ghostty_config_free(first)
            ghostty_config_free(second)
        }
        load("foreground = black", into: first)
        load("foreground = black", into: second)

        let firstIdentity = try #require(
            GhosttyConfigurationContentIdentity(first)
        )
        let secondIdentity = try #require(
            GhosttyConfigurationContentIdentity(second)
        )

        #expect(firstIdentity == secondIdentity)
    }

    @Test
    func differentEffectiveConfigurationsHaveDifferentIdentities() throws {
        let first = try #require(ghostty_config_new())
        let second = try #require(ghostty_config_new())
        defer {
            ghostty_config_free(first)
            ghostty_config_free(second)
        }
        load("foreground = black", into: first)
        load("foreground = white", into: second)

        let firstIdentity = try #require(
            GhosttyConfigurationContentIdentity(first)
        )
        let secondIdentity = try #require(
            GhosttyConfigurationContentIdentity(second)
        )

        #expect(firstIdentity != secondIdentity)
    }

    private func load(
        _ directive: String,
        into configuration: ghostty_config_t
    ) {
        directive.withCString { contents in
            "/__cmux_content_identity__/config".withCString { path in
                ghostty_config_load_string(
                    configuration,
                    contents,
                    UInt(directive.utf8.count),
                    path
                )
            }
        }
        ghostty_config_finalize(configuration)
    }
}
