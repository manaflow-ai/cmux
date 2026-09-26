#if os(iOS)
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShellUI

/// The signed-out SSH shell (no account, no Mac) never shows the Mac-centric
/// What's New sheet ("Enable iOS pairing on your Mac", connection methods),
/// and suppressing it does not mark it seen: a later sign-in still shows it.
@MainActor
@Suite struct MobileWhatsNewAudienceTests {
    private func makeCenter() -> MobileWhatsNewCenter {
        let suiteName = "MobileWhatsNewAudienceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return MobileWhatsNewCenter(
            apiBaseURL: "https://cmux.test",
            appVersion: "1.0.5",
            buildType: .beta,
            defaults: defaults,
            loader: { _ in throw URLError(.notConnectedToInternet) }
        )
    }

    @Test func signedOutSSHShellGetsNoLaunchSheetPages() {
        let center = makeCenter()
        #expect(!center.unseenPages.isEmpty, "precondition: a team build has unseen pages")
        #expect(center.launchSheetPages(for: .signedOutSSH).isEmpty)
    }

    @Test func suppressionLeavesPagesUnseenForALaterSignIn() {
        let center = makeCenter()
        let before = center.unseenPages.map(\.listID)
        _ = center.launchSheetPages(for: .signedOutSSH)
        #expect(center.unseenPages.map(\.listID) == before)
        #expect(center.launchSheetPages(for: .pairedComputers).map(\.listID) == before)
    }
}
#endif
