import Sentry
import Testing
@testable import CmuxNextCrashReporting

/// p06-scheduler-203: a main-thread hang event names what ran, the scheduled task's owner and class
/// as tags and its posting location and the turn so far as extras, or `unattributed`.
@Suite struct MainThreadHangEventAttributionTests {
    @Test func aHangInATaskCarriesItsOwnerClassLocationAndTurn() {
        let attribution = MainThreadHangEvent.Attribution(owner: "SidebarRows", taskClass: "visible",
                                                          location: "CmuxNextSidebar/SidebarRows.swift:42", turnNanos: 2_300_000_000)
        let event = MainThreadHangEvent(duration: .seconds(2), addresses: [], attribution: attribution).event()
        #expect(event.tags?["hang_owner"] == "SidebarRows")
        #expect(event.tags?["hang_class"] == "visible")
        #expect(event.extra?["hang_location"] as? String == "CmuxNextSidebar/SidebarRows.swift:42")
        #expect(event.extra?["turn_ms"] as? Int == 2_300)
        #expect(event.tags?["hang_source"] == "main_thread_watchdog")
    }

    @Test func anUnattributedHangSaysSoAndNamesNoLocation() {
        let attribution = MainThreadHangEvent.Attribution(owner: "unattributed", taskClass: "unattributed", location: nil, turnNanos: 3_000_000_000)
        let event = MainThreadHangEvent(duration: .seconds(2), addresses: [], attribution: attribution).event()
        #expect(event.tags?["hang_owner"] == "unattributed")
        #expect(event.tags?["hang_class"] == "unattributed")
        #expect(event.extra?["hang_location"] == nil)
        #expect(event.extra?["turn_ms"] as? Int == 3_000)
    }

    @Test func noAttributionSetsNoTags() {
        let event = MainThreadHangEvent(duration: .seconds(2), addresses: []).event()
        #expect(event.tags?["hang_owner"] == nil)
        #expect(event.extra?["turn_ms"] == nil)
    }
}
