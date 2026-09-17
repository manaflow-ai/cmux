import CmuxMobileWorkspace
import Testing
@testable import CmuxMobileShellUI

@Suite struct SetupHelpGateContentTests {
    @Test func setupGatesDoNotExposeExternalPurchaseLinks() {
        let gates: [MobileSetupGuidanceState] = [
            .notSignedIn,
            .signedInNeverPaired,
            .macUnreachable,
            .accountMismatch,
        ]

        for gate in gates {
            let url = SetupHelpGateContent.content(for: gate).link?.url.absoluteString
            #expect(url?.contains("founders-edition") != true)
            #expect(url?.contains("github.com/manaflow-ai/cmux") != true)
        }
    }

    @Test(arguments: [
        MobileSetupGuidanceState.signedInNeverPaired,
        .macUnreachable,
    ])
    func MacSetupGatesLinkToTheCanonicalGuide(
        gate: MobileSetupGuidanceState
    ) throws {
        let content = SetupHelpGateContent.content(for: gate)
        let link = try #require(content.link)

        #expect(link.url == SetupHelpGateContent.macOSSetupGuideURL)
        #expect(link.title == "Mac setup guide")
    }

    @Test func signInGateStaysInApp() {
        let content = SetupHelpGateContent.content(for: .notSignedIn)

        #expect(content.link == nil)
    }
}
