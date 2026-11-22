import CmuxNextBrowserImport
import Foundation
import Testing
@testable import CmuxNextOnboarding

/// cx-367y: the cookie import card opens the import step with only cookies
/// checked; finding browsers that can give passwords does not check them,
/// and the person can still check the other kinds.
@MainActor
@Suite struct ImportKindPresetTests {
    func profile(_ dir: String, browser: ImportBrowser) -> BrowserSourceProfile {
        BrowserSourceProfile(browser: browser, directoryName: dir, displayName: dir, path: URL(fileURLWithPath: "/tmp/\(dir)"),
                             availability: [.bookmarks: .available, .cookies: .available, .passwords: .available])
    }

    func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    @Test func aCookiePresetChecksOnlyCookiesEvenWithAPasswordStore() async throws {
        let services = MockOnboardingServices()
        services.passwordStore = true
        let home = profile("Default", browser: .chrome)
        services.sources = [BrowserSource(browser: .chrome, appURL: nil, profiles: [home])]
        let model = OnboardingModel(services: services, start: .importData)
        model.importer.preset(kinds: [.cookies])
        model.importer.detect()
        await settle { model.importer.phase == .ready }
        #expect(model.importer.kinds == [.cookies])
        #expect(model.importer.kindChoices.contains(.passwords), "passwords stay offered")
        #expect(model.importer.passwordProfiles.isEmpty, "so no consent screen comes up")

        model.importer.start()
        await settle { model.importer.summary != nil }
        let plan = try #require(services.plans.first)
        #expect(plan.items.map(\.kinds) == [[.cookies]])
    }

    @Test func thePersonCanStillCheckOtherKinds() async {
        let services = MockOnboardingServices()
        services.sources = [BrowserSource(browser: .chrome, appURL: nil, profiles: [profile("Default", browser: .chrome)])]
        let model = OnboardingModel(services: services, start: .importData)
        model.importer.preset(kinds: [.cookies])
        model.importer.detect()
        await settle { model.importer.phase == .ready }
        model.importer.toggle(.bookmarks)
        #expect(model.importer.kinds == [.cookies, .bookmarks])
    }

    /// cx-lsgf: Import Cookies on the card imports into the profile of the tab that showed it,
    /// so the card's "stay signed in" holds there; any other opening keeps one new profile per source.
    @Test func aCardPresetImportsIntoTheTabsProfileAndOtherOpeningsDoNot() async throws {
        let services = MockOnboardingServices()
        services.sources = [BrowserSource(browser: .chrome, appURL: nil, profiles: [profile("Default", browser: .chrome)])]
        let model = OnboardingModel(services: services, start: .importData)
        let tabProfile = "0b6f3c2e-6a51-4d1f-9a3e-2f6b1c9d7e40"
        model.importer.preset(kinds: [.cookies], into: tabProfile)
        model.importer.detect()
        await settle { model.importer.phase == .ready }
        #expect(model.importer.mergeTarget == tabProfile)
        model.importer.start()
        await settle { model.importer.summary != nil }
        let plan = try #require(services.plans.first)
        #expect(plan.mergeTarget == tabProfile, "the cookies go into the tab's own profile")

        model.importer.resetTarget()
        #expect(model.importer.mergeTarget == nil)
        #expect(model.importer.plan.mergeTarget == nil, "an import opened elsewhere makes one profile per source again")
    }
}

