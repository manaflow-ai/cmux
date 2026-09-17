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

    @Test func signedInNeverPairedGateUsesInAppInstructionsOnly() {
        let content = SetupHelpGateContent.content(for: .signedInNeverPaired)

        #expect(content.link == nil)
    }
}
