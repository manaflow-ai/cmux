#if os(iOS)
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

/// Official (App Store) builds must not render internal build-lane vocabulary
/// (DEV, BETA, INTERNAL, TestFlight) in the What's New compat notice or the
/// Mac-detail presence footer; team channels keep the precise internal copy.
/// App Review rejected the App Store app under Guideline 2.2 for that
/// vocabulary in production UI.
@MainActor
@Suite struct MobileOfficialChannelCopyTests {
    @Test func whatsNewCompatFootnoteIsNeutralOnOfficialBuilds() {
        let official = MobileWhatsNewCatalog.macUpdateFootnote(buildType: .prod)
        #expect(!official.contains("BETA"))
        #expect(official.contains("Requires"))
    }

    @Test func whatsNewCompatFootnoteKeepsRollbackRecipeOnTeamBuilds() {
        let team = MobileWhatsNewCatalog.macUpdateFootnote(buildType: .beta)
        #expect(team.contains("cmux BETA 1.0.4"))
        #expect(team.contains("Requires"))
    }

    @Test func whatsNewCarriesTheCompatNoticeAsFootnoteNotFeatureRow() {
        let page = MobileWhatsNewCatalog.connectionsUpdate
        #expect(page.footnote != nil)
        guard case .features(let features) = page.body else {
            Issue.record("connections update page lost its feature rows")
            return
        }
        #expect(!features.contains { $0.symbol == "exclamationmark.triangle.fill" })
    }

    @Test func presenceFooterIsNeutralOnOfficialBuilds() {
        let official = MacComputerDetailView.presenceFooter(buildType: .prod)
        #expect(!official.contains("DEV"))
        #expect(official.contains("heartbeat"))
    }

    @Test func presenceFooterNamesTheDevRolloutOnTeamBuilds() {
        let team = MacComputerDetailView.presenceFooter(buildType: .dev)
        #expect(team.contains("DEV-only"))
    }
}
#endif
