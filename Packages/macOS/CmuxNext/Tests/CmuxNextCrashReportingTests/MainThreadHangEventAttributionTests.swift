import Sentry
import Testing
@testable import CmuxNextCrashReporting

/// A main-thread hang event names what ran, the scheduled task's owner and class
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

    /// A hang the watchdog caught inside the Chromium message pump is tagged `hang.cef`.
    @Test func aHangInsideTheCEFPumpIsTaggedCEF() {
        let event = MainThreadHangEvent(duration: .seconds(2), addresses: [], phase: "cef_pump", cef: true).event()
        #expect(event.tags?["hang.cef"] == "true")
        #expect(event.tags?["main_thread_phase"] == "cef_pump")
        #expect(MainThreadHangEvent(duration: .seconds(2), addresses: []).event().tags?["hang.cef"] == nil)
    }

    @Test func aLagSpikeInsideTheCEFPumpIsTaggedCEF() {
        let spike = LagSpikeEvent(duration: .milliseconds(300), cpu: .milliseconds(300), addresses: [], cef: true).event()
        #expect(spike.tags?["hang.cef"] == "true")
        #expect(LagSpikeEvent(duration: .milliseconds(300), cpu: .milliseconds(300), addresses: []).event().tags?["hang.cef"] == nil)
    }

    @Test func noAttributionSetsNoTags() {
        let event = MainThreadHangEvent(duration: .seconds(2), addresses: []).event()
        #expect(event.tags?["hang_owner"] == nil)
        #expect(event.extra?["turn_ms"] == nil)
    }
}
