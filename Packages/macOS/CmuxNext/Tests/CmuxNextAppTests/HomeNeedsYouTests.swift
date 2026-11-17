import CmuxHomeCore
@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Chief Home's pinned Needs you section (Leo, via his Chief: "a pinned Needs you view in Chief
/// Home, Feed and iPhone listing items waiting on Leo"): the Feed page's own Needs you view
/// (webviews/src/pages/feed/NeedsYouView.tsx) drawn in the Messages page over the daemon's feed client
/// (`feed.view.read {layout: needs_you}`, no second store); it shows only in a Chief's conversation and
/// only while something waits. It is opt-in (Leo 2026-11-03: "I just wanted to see permission things,
/// period, not a pinned thing by default. Toggle-on, yes"): off by default (`feed.needsYouInChief`),
/// nothing is pinned and the Feed still lists the requests. The page's rows, answers and unmount are
/// webviews/test/home-messages-needs-you.test.tsx.
@MainActor @Suite(.serialized) struct HomeNeedsYouTests {
    @Test func itIsOffByDefaultAndTheSettingTurnsItOn() throws {
        #expect(HomeNeedsYouSetting.fallback == false)
        let unset = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(unset.homeNeedsYouInChief == false, "unset cmux.json: no pinned card")
        let on = CmuxConfigSnapshot.parse(try JSONValue.parse(Data(#"{"feed":{"needsYouInChief":true}}"#.utf8)),
                                          validDensities: [], validMetrics: [])
        #expect(on.homeNeedsYouInChief == true)
        let row = try #require(SettingsSchema.descriptor(for: HomeNeedsYouSetting.configPath))
        #expect(row.defaultValue == .bool(false), "Settings shows it off by default")
    }

    /// The page mounts the Feed's `#/needs-you` only in a Chief's chat with the setting on; another
    /// chat never reads the setting, so its changes never wake that page.
    @Test func onlyAChiefsChatWithTheSettingOnShowsTheFeedsNeedsYou() {
        var reads = 0
        let on = { reads += 1; return true }
        #expect(HomeMessagesHostProvider.needsYouState(isChief: true, enabled: on) == .object(["route": .string("#/needs-you")]))
        #expect(HomeMessagesHostProvider.needsYouState(isChief: true, enabled: { false }) == .null, "off: nothing pinned")
        #expect(HomeMessagesHostProvider.needsYouState(isChief: false, enabled: on) == .null)
        #expect(reads == 1, "a chat that is not a Chief's reads no setting")
    }

    /// While it shows, its calls are the Feed page's (the Feed page's relay and gestures, its actions);
    /// the person's gesture and the op id go with them.
    @Test func itsCallsGoAsTheFeedPagesWithTheGestureKept() {
        let page = PageCallContext(page: PageDescriptor.homeMessages.id, opid: "op-1", userGesture: true, gestureEvent: 42)
        let feed = HomeMessagesHostProvider.asFeedPage(page)
        #expect(feed.page == PageDescriptor.feed.id)
        #expect(feed.opid == "op-1" && feed.userGesture && feed.gestureEvent == 42 && feed.origin == "page" && !feed.confirmed)
        #expect(PageDescriptor.homeMessages.admits("cmux.feed.view.read"), "the page may send the Feed's ops")
        #expect(HomeMessagesPageRoute.needsPerson("needsYou.action", [:]), "its actions run on the person's click only")
    }

    /// Off (or no Chief's chat shown), no part of the Messages page reads the Feed: a `cmux.feed.*`
    /// call or stream and `needsYou.action` are refused before they reach the daemon or the actions.
    @Test func whileItDoesNotShowTheFeedIsRefused() async {
        let services = HomeChiefDefaultTests.services()
        HomeMessagesPageRulesTests.kept.append(services)
        let host = HomeMessagesHostProvider(services: services, widthKey: "test")
        host.needsYouEnabled = { true }
        host.reportShown(HomeChiefRosterTests.ada, composing: false) // a DM, not a Chief's chat
        #expect(host.needsYouState() == .null)
        let context = PageCallContext(page: PageDescriptor.homeMessages.id, userGesture: true, gestureEvent: 1)
        await #expect(throws: PageError.self) {
            _ = try await host.call("cmux.feed.view.read", params: .object(["layout": .string("needs_you")]), context: context)
        }
        await #expect(throws: PageError.self) {
            _ = try await host.call(HomeMessagesPageRoute.prefix + "needsYou.action",
                                    params: .object(["action": .string("feed.openItem")]), context: context)
        }
        await #expect(throws: PageError.self) {
            _ = try await host.subscribe("cmux.feed.view.changed", filter: .null, context: context) { _ in }
        }
    }
}
