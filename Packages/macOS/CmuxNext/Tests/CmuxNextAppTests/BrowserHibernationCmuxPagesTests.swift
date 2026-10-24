import AppKit
@testable import CmuxNextApp
@testable import CmuxNextPages
import CmuxNextSettings
import Testing

/// The app's assembly of the freeze of hidden cmux pages (perf-lead.md F3): the hibernation
/// applies `browser.freezeHiddenTabs` to the policy the app's page host hands to every page. The
/// host was made at launch after the hibernation started and the policy was set on it through an
/// optional cast of a host that did not exist yet, so no cmux page in the app ever reported to it;
/// the policy is now a required argument of the host (`ChromiumPageHost.init`), and `AppDelegate`
/// passes it the one it gives the hibernation. The policy itself is tested in
/// CmuxNextPagesTests/CmuxPageFreezingTests.swift.
@Suite(.serialized)
@MainActor
struct BrowserHibernationCmuxPagesTests {
    @Test func theHibernationKeepsThePagesPolicyOnItsSetting() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let freezing = CmuxPageFreezing()
        let hibernation = BrowserHibernation(cache: services.cache, cmuxPages: freezing)
        #expect(freezing.setting == hibernation.setting)

        var setting = BrowserHibernationSetting.fallback
        setting.freezeSeconds = 120
        hibernation.apply(setting)
        #expect(freezing.setting == setting)
    }
}
