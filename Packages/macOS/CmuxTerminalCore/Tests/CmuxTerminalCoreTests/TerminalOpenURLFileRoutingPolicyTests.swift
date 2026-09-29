import Foundation
import Testing
import CmuxTerminalCore

@Suite struct TerminalOpenURLFileRoutingPolicyTests {
    private let policy = TerminalOpenURLFileRoutingPolicy()

    @Test func explicitFileSchemeBypassesCmuxFileRouting() throws {
        let url = try #require(URL(string: "file:///Users/dev/out/ab_cosyvoice_emo.wav"))
        #expect(
            policy.shouldAttemptCmuxFileRouting(
                rawOpenURLValue: url.absoluteString,
                target: .external(url)
            ) == false
        )
    }

    @Test func localhostFileSchemeBypassesCmuxFileRouting() throws {
        let url = try #require(URL(string: "file://localhost/Users/dev/out/ab_cosyvoice_emo.wav"))
        #expect(
            policy.shouldAttemptCmuxFileRouting(
                rawOpenURLValue: url.absoluteString,
                target: .external(url)
            ) == false
        )
    }

    @Test func hostedFileTargetBypassesCmuxFileRoutingEvenWithoutRawScheme() throws {
        let url = try #require(URL(string: "file://remote-host/Users/dev/out/ab_cosyvoice_emo.wav"))
        #expect(
            policy.shouldAttemptCmuxFileRouting(
                rawOpenURLValue: "/Users/dev/out/ab_cosyvoice_emo.wav",
                target: .external(url)
            ) == false
        )
    }

    @Test func absolutePathCanStillUseCmuxFileRouting() {
        let url = URL(fileURLWithPath: "/Users/dev/project/README.md")
        #expect(
            policy.shouldAttemptCmuxFileRouting(
                rawOpenURLValue: "/Users/dev/project/README.md",
                target: .external(url)
            )
        )
    }

    @Test func nonFileTargetsBypassCmuxFileRouting() throws {
        let url = try #require(URL(string: "https://example.com/audio.wav"))
        #expect(
            policy.shouldAttemptCmuxFileRouting(
                rawOpenURLValue: url.absoluteString,
                target: .embeddedBrowser(url)
            ) == false
        )
    }

    // Ghostty sends configured path-regex matches through the same
    // `open_url` callback as URLs, so a scheme-less mismatched wrapped-path
    // fragment (`TerminalLinkOpenCoordinator`'s fail-closed guard) needs to
    // tell a stale local path apart from a real bare host — otherwise
    // `research/docs/report.md` gets misinterpreted as `https://research`.
    @Test(
        "Scheme-less local path intent is distinguished from web hosts",
        arguments: [
            ("research/docs/notes/report.md", true),
            ("./research/docs/notes/report.md", true),
            ("../research/docs/notes/report.md", true),
            ("~/research/docs/notes/report.md", true),
            ("/Users/dev/research/docs/notes/report.md", true),
            ("example.com/docs/report.md", false),
            ("example.com:8080/docs/report.md", false),
            ("localhost/docs/report.md", false),
            ("127.0.0.1/docs/report.md", false),
            ("user@host/path", false),
            ("https://example.com/docs/report.md", false),
        ]
    )
    func localPathIntent(rawValue: String, expected: Bool) {
        #expect(policy.isLikelyLocalPathReference(rawValue) == expected)
    }
}
