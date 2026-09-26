#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

/// Official (App Store) builds must not render internal build-lane vocabulary
/// (DEV, BETA, INTERNAL, TestFlight) in compatibility copy or the Mac-detail
/// presence footer; team channels keep the precise internal copy.
/// App Review rejected the App Store app under Guideline 2.2 for that
/// vocabulary in production UI.
@MainActor
@Suite struct MobileOfficialChannelCopyTests {
    @Test func whatsNewCompatCopyIsNeutralOnOfficialBuilds() {
        let official = MobileWhatsNewCatalog().macCompatibility(
            policy: .baked,
            iosVersion: "1.0.4",
            buildType: .prod
        )
        #expect(official.stableVersion == "0.64.25")
        #expect(official.nightlyVersion?.contains("nightly") == true)
    }

    @Test func whatsNewCompatCopyUsesTeamSpecificFloor() {
        let team = MobileWhatsNewCatalog().macCompatibility(
            policy: .baked,
            iosVersion: "1.0.4",
            buildType: .beta
        )
        #expect(team.stableVersion == "0.64.20")
        // The 1.0.6 compatibility release (#14112) gave the baked 1.0.4 beta
        // tier the historical nightly floor; before that it had none.
        #expect(team.nightlyVersion == "0.64.22-nightly.3345650013202")
    }

    @Test func whatsNewMacUpdateDetailUsesTheResolvedFloor() {
        let team = MobileWhatsNewCatalog().macUpdateDetail(
            buildType: .beta,
            requiredVersion: "0.64.20"
        )
        #expect(team.contains("0.64.20"))
        #expect(team.contains("BETA"))
        #expect(!team.contains("%@"))

        let official = MobileWhatsNewCatalog().macUpdateDetail(
            buildType: .prod,
            requiredVersion: "0.64.25"
        )
        #expect(official.contains("0.64.25"))
        #expect(!official.contains("BETA"))
        #expect(!official.contains("%@"))
    }

    @Test func whatsNewUsesTheCustomPairingPage() throws {
        let page = try #require(MobileWhatsNewCatalog().entry(withID: "connections.v2"))
        #expect(page.footnote == nil)
        guard case .pairingSetup(let features) = page.body else {
            Issue.record("connections update page lost its custom body")
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
