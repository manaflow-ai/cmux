import CmuxNextBrowserImport
@testable import CmuxNextOnboarding
import Testing

/// The first-run import card's plan (RFD 0125 D4): its defaults, the stated cookie
/// replacement, the mirror line and the popup's rows.
@Suite struct FirstRunImportPlanTests {
    let profiles = [FirstRunImportPlan.Profile(id: "default", name: "Default"), FirstRunImportPlan.Profile(id: "p2", name: "Work")]

    @Test func defaultsCheckD4Kinds() {
        let plan = FirstRunImportPlan(browser: .chrome, sourceProfile: "Chrome", profiles: profiles, mirrorOn: true)
        #expect(plan.kinds == [.bookmarks, .history, .passwords, .cookies, .searchEngines])
        #expect(!plan.kinds.contains(.extensions))
        #expect(!plan.kinds.contains(.openTabs))
        #expect(plan.canImport)
    }

    @Test func destinationDefaultsToFirstProfileElseNew() {
        #expect(FirstRunImportPlan(browser: .chrome, sourceProfile: "Chrome", profiles: profiles, mirrorOn: true).destination == .existing(profiles[0]))
        let fresh = FirstRunImportPlan(browser: .chrome, sourceProfile: "Chrome", profiles: [], mirrorOn: true)
        #expect(fresh.destination == .newProfile)
        #expect(fresh.importTarget == nil)
        #expect(fresh.destinationIndex == 0)
    }

    @Test func replaceCookiesStatedOnlyForExistingProfileWithSignIns() {
        var plan = FirstRunImportPlan(browser: .chrome, sourceProfile: "Chrome", profiles: profiles, mirrorOn: true)
        #expect(plan.replacesCookies)
        plan.toggle(.cookies)
        #expect(!plan.replacesCookies)
        plan.toggle(.cookies)
        plan.selectDestination(at: 0)
        #expect(plan.destination == .newProfile)
        #expect(!plan.replacesCookies)
    }

    @Test func popupRowsMapToProfiles() {
        var plan = FirstRunImportPlan(browser: .chrome, sourceProfile: "Chrome", profiles: profiles, mirrorOn: true)
        plan.selectDestination(at: 2)
        #expect(plan.importTarget == "p2")
        #expect(plan.destinationIndex == 2)
        plan.selectDestination(at: 9)
        #expect(plan.destination == .newProfile)
    }

    @Test func mirrorFollowsSettingFamilyAndSignIns() {
        var chrome = FirstRunImportPlan(browser: .chrome, sourceProfile: "Chrome", profiles: profiles, mirrorOn: true)
        #expect(chrome.offersMirror)
        #expect(chrome.mirrors)
        chrome.mirrorOn = false
        #expect(!chrome.mirrors)
        chrome.mirrorOn = true
        chrome.toggle(.cookies)
        #expect(!chrome.mirrors)
        let safari = FirstRunImportPlan(browser: .safari, sourceProfile: "Safari", profiles: profiles, mirrorOn: true)
        #expect(!safari.offersMirror)
        #expect(!safari.mirrors)
    }

    @Test func nothingCheckedCannotImport() {
        var plan = FirstRunImportPlan(browser: .chrome, sourceProfile: "Chrome", profiles: [], mirrorOn: true)
        for kind in plan.kinds { plan.toggle(kind) }
        #expect(!plan.canImport)
    }
}
