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
    @Test func whatsNewCompatNoticeIsNeutralOnOfficialBuilds() {
        let official = MobileWhatsNewCatalog.macUpdateDetail(buildType: .prod)
        #expect(!official.contains("TestFlight"))
        #expect(!official.contains("BETA"))
        #expect(official.contains("Update cmux on your Mac"))
    }

    @Test func whatsNewCompatNoticeKeepsRollbackRecipeOnTeamBuilds() {
        let team = MobileWhatsNewCatalog.macUpdateDetail(buildType: .beta)
        #expect(team.contains("TestFlight"))
        #expect(team.contains("Update cmux on your Mac"))
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
