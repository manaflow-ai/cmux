import CmuxUpdater
import Foundation
import Testing
@testable import CmuxNextUpdater

/// R114 what's-new card: first launch of a new build with human highlights
/// only; never on a fresh install; never again after that launch.
@MainActor
@Suite struct UpdaterWhatsNewTests {
    private func notes(_ build: String, highlights: Bool) -> ReleaseNotes {
        ReleaseNotes(version: 1, build: build, shortVersion: "1.0.0-nightly.\(build)", date: "2026-10-05",
                     highlights: highlights ? [.init(id: "h", title: "Hello", body: "", media: [], action: nil)] : [], changes: [])
    }

    private func service(build: String, defaults: UserDefaults, notes: ReleaseNotes?) -> UpdaterService {
        let service = UpdaterService(identity: AppcastFixtures.identity(bundle: "com.cmuxterm.app.nightly", build: build,
                                                                        feed: "https://files-next.cmux.com/nightly-next/appcast.xml"),
                                     policy: ManagedUpdatePolicy { false }, defaults: defaults, enableSparkle: false)
        service.notesLoader = { _ in notes }
        return service
    }

    private func store() -> UserDefaults { UserDefaults(suiteName: "whats-new-\(UUID().uuidString)")! }

    @Test func aFreshInstallShowsNoCard() async {
        let defaults = store()
        let first = service(build: "10", defaults: defaults, notes: notes("10", highlights: true))
        await first.loadWhatsNew()?.value
        #expect(first.whatsNew == nil)
        #expect(defaults.string(forKey: UpdaterService.lastSeenBuildKey) == "10")
    }

    @Test func theFirstLaunchOfANewBuildWithHighlightsShowsItOnce() async {
        let defaults = store()
        defaults.set("9", forKey: UpdaterService.lastSeenBuildKey)
        let updated = service(build: "10", defaults: defaults, notes: notes("10", highlights: true))
        await updated.loadWhatsNew()?.value
        #expect(updated.whatsNew?.build == "10")
        let relaunched = service(build: "10", defaults: defaults, notes: notes("10", highlights: true))
        await relaunched.loadWhatsNew()?.value
        #expect(relaunched.whatsNew == nil)
        updated.dismissWhatsNew()
        #expect(updated.whatsNew == nil)
    }

    @Test func aBuildWithoutHighlightsShowsNothing() async {
        let defaults = store()
        defaults.set("9", forKey: UpdaterService.lastSeenBuildKey)
        let updated = service(build: "10", defaults: defaults, notes: notes("10", highlights: false))
        await updated.loadWhatsNew()?.value
        #expect(updated.whatsNew == nil)
        #expect(defaults.string(forKey: UpdaterService.lastSeenBuildKey) == "10")
    }
}
