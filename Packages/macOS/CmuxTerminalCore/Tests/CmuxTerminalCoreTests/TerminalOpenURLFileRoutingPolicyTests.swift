import Foundation
import Testing
import CmuxTerminalCore

@Suite struct TerminalOpenURLFileRoutingPolicyTests {
    private let policy = TerminalOpenURLFileRoutingPolicy()

    @Test(arguments: [true, false])
    func explicitFileSchemeBypassesCmuxFileRouting(_: Bool) throws {
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
}
