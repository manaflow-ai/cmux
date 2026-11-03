@testable import CmuxNextApp
import CmuxNextHibernation
@testable import CmuxNextSettings
import Foundation
import Testing

/// Idle power (msg 2654): a hidden Chromium page keeps its renderer awake about 0.5 to 1.5 times
/// a second. Freezing it (`Page.setWebLifecycleState frozen`) cut renderer energy by about 90 %
/// on cmux14, but hibernation only closes a page after 60 minutes hidden. A hidden page freezes
/// after `browser.freezeHiddenTabs` seconds (30 by default) and thaws when shown.
@Suite struct HiddenPageFreezeTests {
    private func candidate(_ key: String, hiddenFor: Double, pinned: Bool = false, host: String? = nil) -> HibernationPlanner.Candidate {
        HibernationPlanner.Candidate(key: key, hiddenFor: hiddenFor, host: host, isPinned: pinned)
    }

    @Test func aHiddenPageFreezesAfterThirtySecondsByDefault() {
        #expect(BrowserHibernationSetting.fallback.freezeSeconds == 30)
        let plan = HibernationPlanner.freezePlan(.fallback, candidates: [
            candidate("long", hiddenFor: 31), candidate("short", hiddenFor: 10),
        ])
        #expect(plan.due == ["long"])
        #expect(abs((plan.nextCheck ?? 0) - 20) < 1e-9)
    }

    /// Freezing stops a page's timers and sockets, so the pages a person keeps live for
    /// notifications (pinned tabs, excluded hosts) stay awake as they do for hibernation.
    @Test func pinnedAndExcludedPagesStayAwake() {
        var setting = BrowserHibernationSetting.fallback
        setting.exclusions = ["mail.google.com"]
        let plan = HibernationPlanner.freezePlan(setting, candidates: [
            candidate("pinned", hiddenFor: 100, pinned: true),
            candidate("mail", hiddenFor: 100, host: "mail.google.com"),
        ])
        #expect(plan.due.isEmpty)
        #expect(plan.nextCheck == nil)
    }

    @Test func offNeverFreezes() {
        var setting = BrowserHibernationSetting.fallback
        setting.freezeSeconds = nil
        let plan = HibernationPlanner.freezePlan(setting, candidates: [candidate("a", hiddenFor: 1_000)])
        #expect(plan.due.isEmpty)
        #expect(plan.nextCheck == nil)
    }

    /// Hibernation "off" leaves freezing on: it closes no page and loses no state.
    @Test func freezingIsIndependentOfHibernation() {
        let setting = BrowserHibernationSetting(mode: .off)
        #expect(HibernationPlanner.freezePlan(setting, candidates: [candidate("a", hiddenFor: 31)]).due == ["a"])
    }

    @Test(arguments: [
        (CmuxNextSettings.JSONValue.string("off"), Double?.none),
        (CmuxNextSettings.JSONValue.number(45), Double?.some(45)),
    ])
    func theSettingParses(value: CmuxNextSettings.JSONValue, expected: Double?) {
        let (setting, diagnostics) = BrowserHibernationSetting.parse(.object(["browser": .object(["freezeHiddenTabs": value])]))
        #expect(diagnostics.isEmpty)
        #expect(setting.freezeSeconds == expected)
    }

    @Test func aBadValueKeepsTheDefault() {
        let (setting, diagnostics) = BrowserHibernationSetting.parse(.object(["browser": .object(["freezeHiddenTabs": .string("soon")])]))
        #expect(setting.freezeSeconds == 30)
        #expect(diagnostics.map(\.path) == ["browser.freezeHiddenTabs"])
    }
}
