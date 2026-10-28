import AppKit
import CmuxHomeCore
@testable import CmuxNextApp
import CmuxNextHomeEngine
import CmuxNextWakeups
import Foundation
import Testing

/// The Home page while the last launch's list is still being read (p08-startup-076): the read is held, so the page
/// draws only the theme background (no list, no rows from an unprimed store); once it lands, the cached list shows
/// whole. Before, the list drew its first frames empty and each piece popped in when the read landed.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct HomeListLaunchGateTests {
    @Test func aHeldReadShowsNoRowsThenTheCachedListWhenItLands() async throws {
        _ = NSApplication.shared
        let caches = FileManager.default.temporaryDirectory.appendingPathComponent("home-list-gate-\(UUID().uuidString)", isDirectory: true)
        var environment = AppEnvironment.current([:])
        environment.homeCachesDirectory = caches
        let owner = ChiefHome.resolve(tag: environment.tag).session
        let me = Participant(id: ParticipantID("user_me"), kind: .human, displayName: "Me")
        let ada = Participant(id: ParticipantID("user_ada"), kind: .human, displayName: "Ada Lovelace")
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        var snapshot = HomeCacheSnapshot()
        snapshot.me = me
        snapshot.conversations = [CmuxHomeCore.ConversationSummary(id: ConversationID("conv_gate_ada"), owner: .local, title: "Ada",
                                                                   participants: [me, ada], createdAt: at, updatedAt: at)]
        let cached = snapshot
        let gate = DispatchSemaphore(value: 0)
        environment.homeListRead = HomeListLaunchRead(owner: owner, caches: caches, conversations: HomeCache.standard(owner: owner, caches: caches),
                                                      sidebar: HomeSidebarLaunchCache.standard(owner: owner, caches: caches, files: BackgroundWork()),
                                                      on: BackgroundWork()) {
            gate.wait()
            return HomeListLaunchRead.Value(conversations: cached)
        }
        let services = AppServices(environment: environment)
        #expect(services.home.listLaunch.read.owner == owner && services.home.listLaunch.read.caches == caches,
                "the Home service did not take the launch's read")

        let page = TopHomePageView(services: services, windowKey: { "home-list-gate" })
        #expect(!services.home.listLaunch.isLanded)
        #expect(page.rows.isEmpty, "the page listed rows before the read landed")
        #expect(page.split.isHidden, "the page drew its list before the read landed")

        gate.signal()
        let landed = await HomeChiefHostedSettingsTests.eventually { !page.rows.isEmpty }
        try #require(landed, "the cached list never showed")
        #expect(services.home.listLaunch.isLanded)
        #expect(page.rows.map(\.id) == [ConversationID("conv_gate_ada")], "the page showed another list than the cache's")
        #expect(!page.split.isHidden, "the list stayed hidden after the read landed")
    }
}
