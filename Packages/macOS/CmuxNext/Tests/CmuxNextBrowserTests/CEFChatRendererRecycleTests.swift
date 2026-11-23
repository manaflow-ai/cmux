@testable import CmuxNextBrowser
import Foundation
import Testing

@MainActor
@Suite struct CEFChatRendererRecycleTests {
    private let mb = 1 << 20

    @Test func onlyOneTurnsItOn() {
        #expect(CEFChatRendererRecycle.isEnabled([CEFChatRendererRecycle.environmentKey: "1"]))
        #expect(!CEFChatRendererRecycle.isEnabled([CEFChatRendererRecycle.environmentKey: "0"]))
        #expect(!CEFChatRendererRecycle.isEnabled([CEFChatRendererRecycle.environmentKey: "true"]))
        #expect(!CEFChatRendererRecycle.isEnabled([:]))
    }

    @Test func boundIsTwiceTheBaselineAndAtLeastTheFloorMore() {
        #expect(CEFChatRendererRecycle.bound(baseline: 150 * mb) == 406 * mb)
        #expect(CEFChatRendererRecycle.bound(baseline: 300 * mb) == 600 * mb)
        #expect(CEFChatRendererRecycle.bound(baseline: 256 * mb) == 512 * mb)
        #expect(CEFChatRendererRecycle.bound(baseline: -1) == 256 * mb)
    }

    @Test func thePersonIsAwayAfterThirtyQuietSecondsOrWithTheAppInactive() {
        #expect(!CEFChatRendererRecycle.personIdle(secondsSinceInput: 29.9, appActive: true))
        #expect(CEFChatRendererRecycle.personIdle(secondsSinceInput: 30, appActive: true))
        #expect(CEFChatRendererRecycle.personIdle(secondsSinceInput: 0, appActive: false))
    }

    @Test func firstSightRecordsABaselineAtMostAFreshRenderer() {
        var state = CEFChatRendererRecycle()
        let now = ContinuousClock.now
        // Seen first at 675 MB: its baseline is a fresh renderer's 192 MB, so 675 >= 448 is due at once.
        #expect(state.isDue(renderer: 7, resident: 675 * mb, now: now, live: [7]))
        // Seen first small: the baseline is what it holds.
        #expect(!state.isDue(renderer: 8, resident: 120 * mb, now: now, live: [7, 8]))
        #expect(!state.isDue(renderer: 8, resident: 375 * mb, now: now, live: [7, 8]))
        #expect(state.isDue(renderer: 8, resident: 376 * mb, now: now, live: [7, 8]))
    }

    @Test func oneRecycleInTenMinutesForEveryRenderer() {
        var state = CEFChatRendererRecycle()
        let start = ContinuousClock.now
        #expect(state.isDue(renderer: 7, resident: 700 * mb, now: start, live: [7]))
        state.recycled(at: start)
        // The fresh renderer comes back under a new client id: the cooldown still holds.
        #expect(!state.isDue(renderer: 9, resident: 700 * mb, now: start + .seconds(599), live: [9]))
        #expect(state.isDue(renderer: 9, resident: 700 * mb, now: start + .seconds(600), live: [9]))
    }

    @Test func settledSizeIsTheNextBaselineAndDeadRenderersAreForgotten() {
        var state = CEFChatRendererRecycle()
        let now = ContinuousClock.now
        state.settled(renderer: 9, resident: 160 * mb)
        #expect(!state.isDue(renderer: 9, resident: 400 * mb, now: now, live: [9]))
        #expect(state.isDue(renderer: 9, resident: 416 * mb, now: now, live: [9]))
        // Gone from the live set, then seen again: a new first sight.
        _ = state.isDue(renderer: 10, resident: 100 * mb, now: now, live: [10])
        #expect(state.isDue(renderer: 9, resident: 448 * mb, now: now, live: [9, 10]))
    }

    @Test func recyclesWhenEveryPageIsASpareOrAnIdleChat() {
        let pages: [CEFChatRendererRecycle.Page] = [.spare, .idleChat(key: "a", shown: true), .idleChat(key: "b", shown: false), .spare]
        #expect(CEFChatRendererRecycle.decide(pages, personIdle: true, shuttingDown: false) == .recycle(release: ["a", "b"], show: ["a"]))
    }

    @Test func onePageThatKeepsItLeavesTheRenderer() {
        let pages: [CEFChatRendererRecycle.Page] = [.idleChat(key: "a", shown: true), .keeps("agentBusy"), .spare]
        #expect(CEFChatRendererRecycle.decide(pages, personIdle: true, shuttingDown: false) == .skip("agentBusy"))
    }

    @Test func noRecycleWhileThePersonIsHereOrTheAppQuits() {
        let pages: [CEFChatRendererRecycle.Page] = [.idleChat(key: "a", shown: true)]
        #expect(CEFChatRendererRecycle.decide(pages, personIdle: false, shuttingDown: false) == .skip("the person is using the app"))
        #expect(CEFChatRendererRecycle.decide(pages, personIdle: true, shuttingDown: true) == .skip("shutting down"))
    }

    @Test func onlySparesIsNothingToWin() {
        #expect(CEFChatRendererRecycle.decide([.spare, .spare], personIdle: true, shuttingDown: false) == .skip("no chat page"))
        #expect(CEFChatRendererRecycle.decide([], personIdle: true, shuttingDown: false) == .skip("no chat page"))
    }

    @Test func tabPagesFollowTheHiddenPagePolicy() {
        #expect(CEFChatRendererRecycle.tabPage(key: "n", newTab: true, reservedUntouched: true, exemption: nil, shown: false) == .spare)
        #expect(CEFChatRendererRecycle.tabPage(key: "n", newTab: true, reservedUntouched: false, exemption: nil, shown: false) == .keeps("a New Tab page"))
        #expect(CEFChatRendererRecycle.tabPage(key: "c", newTab: false, reservedUntouched: false, exemption: "agentTurnsUnknown", shown: true) == .keeps("agentTurnsUnknown"))
        #expect(CEFChatRendererRecycle.tabPage(key: "c", newTab: false, reservedUntouched: false, exemption: nil, shown: true) == .idleChat(key: "c", shown: true))
    }
}
