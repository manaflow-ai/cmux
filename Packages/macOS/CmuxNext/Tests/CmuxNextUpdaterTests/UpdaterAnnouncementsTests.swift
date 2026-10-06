import CmuxUpdater
import Foundation
import Testing
@testable import CmuxNextUpdater

/// R114 announcements: hide permanently, bring back, no network when
/// fetching is off, and dismissals persist on this Mac.
@MainActor
@Suite struct UpdaterAnnouncementsTests {
    private nonisolated final class Calls: @unchecked Sendable { var count = 0 }

    private func service(_ defaults: UserDefaults, _ calls: Calls) -> UpdaterService {
        let service = UpdaterService(identity: AppcastFixtures.identity(bundle: "com.cmuxterm.app.nightly", build: "10",
                                                                        feed: "https://files-next.cmux.com/nightly-next/appcast.xml"),
                                     policy: ManagedUpdatePolicy { false }, defaults: defaults, enableSparkle: false)
        service.announcementsLoader = {
            calls.count += 1
            return [Announcement(id: "a", title: "A"), Announcement(id: "b", title: "B")]
        }
        return service
    }

    @Test func loadsAndDismissalsPersist() async {
        let defaults = UserDefaults(suiteName: "ann-\(UUID().uuidString)")!
        let calls = Calls()
        let first = service(defaults, calls)
        await first.refreshAnnouncements()?.value
        #expect(first.announcements.map(\.id) == ["a", "b"])
        first.dismissAnnouncement("a")
        #expect(first.announcements.map(\.id) == ["b"])
        let relaunched = service(defaults, calls)
        await relaunched.refreshAnnouncements()?.value
        #expect(relaunched.announcements.map(\.id) == ["b"])
    }

    @Test func hiddenMeansNoCardsAndNoFetch() async {
        let defaults = UserDefaults(suiteName: "ann-\(UUID().uuidString)")!
        let calls = Calls()
        let service = service(defaults, calls)
        service.announcementsEnabled = false
        await service.refreshAnnouncements()?.value
        #expect(service.announcements.isEmpty)
        #expect(calls.count == 0)
        service.announcementsEnabled = true
        await service.refreshAnnouncements()?.value
        #expect(service.announcements.map(\.id) == ["a", "b"])
    }

    @Test func fetchOffNeverTouchesTheNetwork() async {
        let defaults = UserDefaults(suiteName: "ann-\(UUID().uuidString)")!
        let calls = Calls()
        let service = service(defaults, calls)
        service.announcementsFetch = false
        await service.refreshAnnouncements()?.value
        #expect(calls.count == 0)
        #expect(service.announcements.isEmpty)
    }
}
