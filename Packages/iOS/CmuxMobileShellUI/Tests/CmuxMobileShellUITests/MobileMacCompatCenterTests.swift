#if os(iOS)
import CmuxMobileShell
import Foundation
import Testing
@testable import CmuxMobileShellUI

/// The policy cache must not let an older iOS binary weaken a newer binary's
/// baked floor while the newer binary is offline or its refresh fails.
@MainActor
@Suite struct MobileMacCompatCenterTests {
    @Test func appUpgradeDoesNotReuseOlderBuildPolicy() async {
        let suiteName = "MobileMacCompatCenterTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let oldBuild = MobileMacCompatCenter(
            apiBaseURL: "https://cmux.test",
            defaults: defaults,
            loader: { _ in Data(#"{"entries":[]}"#.utf8) },
            appBuildIdentity: "old-build"
        )
        await oldBuild.refresh()
        #expect(oldBuild.policy.tiers.isEmpty)

        let newBuild = MobileMacCompatCenter(
            apiBaseURL: "https://cmux.test",
            defaults: defaults,
            loader: { _ in throw URLError(.notConnectedToInternet) },
            appBuildIdentity: "new-build"
        )
        #expect(newBuild.policy == .baked)

        let evictedOldBuild = MobileMacCompatCenter(
            apiBaseURL: "https://cmux.test",
            defaults: defaults,
            loader: { _ in throw URLError(.notConnectedToInternet) },
            appBuildIdentity: "old-build"
        )
        #expect(evictedOldBuild.policy == .baked)
    }
}
#endif
