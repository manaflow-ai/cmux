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

    /// The What's New copy on a team build must show that build kind's own
    /// floor (stable and nightly) from the compat policy, never the App Store
    /// floor. The expected nightly is derived from the policy's BETA
    /// requirement rather than hardcoded, so the exact floor values stay
    /// owned by `MobileMacCompatPolicyTests` and `web/data/mobile-mac-compat.ts`.
    @Test func whatsNewCompatCopyUsesTeamSpecificFloor() throws {
        let catalog = MobileWhatsNewCatalog()
        let team = catalog.macCompatibility(
            policy: .baked,
            iosVersion: "1.0.4",
            buildType: .beta
        )
        let official = catalog.macCompatibility(
            policy: .baked,
            iosVersion: "1.0.4",
            buildType: .prod
        )
        let tier = try #require(MobileMacCompatPolicy.baked.tier(forIOSVersion: "1.0.4"))
        let beta = try #require(tier.buildKinds[MobileBuildType.beta.token])

        #expect(team.stableVersion == "0.64.20")
        #expect(team.stableVersion == beta.stableMinVersion.description)
        let betaNightly = try #require(beta.nightly)
        #expect(team.nightlyVersion ==
            "\(betaNightly.minBaseVersion.description)-nightly.\(betaNightly.minBuild)")
        #expect(team.stableVersion != official.stableVersion)
        #expect(team.nightlyVersion != official.nightlyVersion)
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
