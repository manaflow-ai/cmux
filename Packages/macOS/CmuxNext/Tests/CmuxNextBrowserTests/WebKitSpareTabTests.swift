import AppKit
@testable import CmuxNextBrowser
import CmuxNextCompat
import Foundation
import Testing
import CmuxNextWakeupsTestSupport

/// A new WebKit tab takes the tab made ahead at an idle moment (`WebKitSpareTab`) instead of building its
/// `WKWebView`, container and script handlers on the input's turn (29-34 ms of main thread per new tab,
/// `switch.content` in `cef-tab-bench.py`'s `webkit_new`, fleet step d5608a55). Without the spare, every
/// `makeWebKitTab` builds a new view and the first expectation below fails.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct WebKitSpareTabTests {
    private final class Input {
        var count: UInt64 = 0
        var enabled = true
    }

    private struct Rig {
        let engine: WebKitEngine
        let clock: ManualClock
        let input: Input
        let pressure: ManualMemoryPressureSource
        let events: MemoryPressureEvents
        var spare: WebKitSpareTab { engine.spareTab }

        /// Moves past the idle deadline the spare waits on, then lets its build run.
        func idle() async throws {
            try await clock.waitForSleeper()
            clock.advance(by: WebKitSpareTab.Policy().idleInput)
            for _ in 0..<200 where spare.tab == nil { await Task.yield() }
        }
    }

    private func rig() -> Rig {
        let clock = ManualClock(), input = Input(), pressure = ManualMemoryPressureSource()
        let events = MemoryPressureEvents(source: pressure)
        let spare = WebKitSpareTab(clock: clock, activity: { input.count }, isTrackingMenu: { false },
                                   isEnabled: { input.enabled }, memoryPressure: events)
        return Rig(engine: WebKitEngine(fileInput: NoFileInput(), stores: .inMemory(), spareTab: spare),
                   clock: clock, input: input, pressure: pressure, events: events)
    }

    @Test func aNewDefaultTabTakesTheTabMadeAheadAndLoadsItsAddressInIt() async throws {
        let rig = rig()
        defer { rig.spare.drop() }
        #expect(rig.spare.state == "none", "no WebKit tab is likely yet: nothing is made")
        let first = rig.engine.makeWebKitTab()
        defer { first.close() }
        try await rig.idle()
        let made = try #require(rig.spare.tab, "the idle moment after a WebKit tab made no spare")
        #expect(made !== first)

        let id = BrowserTabID.random()
        let url = try #require(URL(string: "about:blank#spare"))
        let second = rig.engine.makeWebKitTab(id: id, initialURL: url)
        defer { second.close() }
        #expect(second === made, "the new tab built its own view instead of taking the one made ahead")
        #expect(second.id == id)
        #expect(rig.spare.taken == 1)
        #expect(rig.spare.tab == nil)
        #expect(second.webView.backForwardList.backList.isEmpty, "the spare must have no history before its first page")
        #expect(rig.spare.state == "scheduled", "a take asks for the next spare at the next idle moment")

        try await rig.idle()
        #expect(rig.spare.tab != nil && rig.spare.tab !== second, "the next idle moment made the next spare")
    }

    @Test func inputDuringTheWaitPutsTheSpareOffToALaterIdleMoment() async throws {
        let rig = rig()
        defer { rig.spare.drop() }
        rig.spare.noteLikely()
        try await rig.clock.waitForSleeper()
        rig.input.count += 1
        rig.clock.advance(by: WebKitSpareTab.Policy().idleInput)
        for _ in 0..<50 { await Task.yield() }
        #expect(rig.spare.tab == nil, "a spare was built right after input")
        #expect(rig.spare.state == "scheduled")
        try await rig.idle()
        #expect(rig.spare.tab != nil)
    }

    @Test func anotherProfileAndAPageOpenedWindowMakeTheirOwnView() async throws {
        let rig = rig()
        defer { rig.spare.drop() }
        rig.spare.noteLikely()
        try await rig.idle()
        let made = try #require(rig.spare.tab)
        let other = rig.engine.makeWebKitTab(profile: BrowserProfileID(rawValue: UUID()))
        defer { other.close() }
        #expect(other !== made && rig.spare.tab === made, "another profile's tab took the default profile's spare")
        let opened = rig.engine.makeWebKitTab(webViewConfiguration: made.webView.configuration)
        defer { opened.close() }
        #expect(opened !== made && rig.spare.tab === made, "a page-opened window took the spare")
    }

    @Test func memoryPressureDropsTheSpareAndMakesNoneUntilNormal() async throws {
        let rig = rig()
        defer { rig.spare.drop() }
        rig.spare.noteLikely()
        try await rig.idle()
        #expect(rig.spare.tab != nil)
        rig.pressure.send(.warning)
        #expect(rig.spare.tab == nil && rig.spare.state == "none", "a warning kept the spare")
        let tab = rig.engine.makeWebKitTab()
        defer { tab.close() }
        #expect(rig.spare.state == "none", "a spare was asked for under pressure")
        rig.pressure.send(.normal)
        try await rig.idle()
        #expect(rig.spare.tab != nil, "back to normal: the next idle moment makes the spare again")
    }

    @Test func switchedOffEveryTabBuildsItsOwnViewAndAWaitingSpareCloses() async throws {
        let rig = rig()
        defer { rig.spare.drop() }
        rig.spare.noteLikely()
        try await rig.idle()
        let made = try #require(rig.spare.tab)
        rig.input.enabled = false
        let tab = rig.engine.makeWebKitTab()
        defer { tab.close() }
        #expect(tab !== made)
        #expect(rig.spare.tab == nil && rig.spare.state == "none")
    }
}
