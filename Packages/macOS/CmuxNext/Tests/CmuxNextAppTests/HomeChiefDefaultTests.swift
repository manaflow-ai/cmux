import AppKit
import CmuxHomeCore
@testable import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextHome
import CmuxNextHostedChief
@testable import CmuxNextSettings
import Foundation
import Testing

/// The default Chief (#64, 2026-10-21): this Mac's Chief while this Mac's optchat-chief runs, the
/// Hosted (cloud) Chief otherwise. Settings > Chief's Engine row (`home.chiefEngine`, Leo's list
/// 89(3)) can force either one; it is the person's setting, no longer a Debug choice.
@MainActor @Suite(.serialized)
struct HomeChiefDefaultTests {
    static let local = "conv_local"
    static let hosted = CloudChief(id: "chief_hosted", displayName: "Chief", isDefault: true, mainConversation: "conv_hosted", rev: 1)
    static let placed = CloudChief(id: "chief_placed", displayName: "Chief", isDefault: false, mainConversation: "conv_placed", rev: 1,
                                   brainPlace: .init(host: "host_mini", install: "install_1"))

    // MARK: The choice

    @Test func theEngineSettingNamesEachChoiceAndDebugNoLongerDoes() {
        #expect(HomeChiefDefault.allCases.map(\.rawValue) == ["auto", "local", "hosted"])
        #expect(HomeChiefDefault(setting: "hosted") == .hosted)
        #expect(HomeChiefDefault(setting: "cloud9") == .auto, "an unknown value is Auto")
        #expect(!HomeTunables.all.contains { $0.key == "home.chiefDefault" }, "promoted out of Debug Settings")
    }

    @Test func autoFollowsWhetherThisMacsChiefRuns() {
        #expect(HomeChiefDefault.auto.prefersLocal(localRunning: true))
        #expect(!HomeChiefDefault.auto.prefersLocal(localRunning: false))
        #expect(HomeChiefDefault.local.prefersLocal(localRunning: false), "Local is forced")
        #expect(!HomeChiefDefault.hosted.prefersLocal(localRunning: true), "Hosted is forced")
    }

    // MARK: The Chief tab and the list's Main

    @Test func theChiefTabShowsThisMacsChiefWhenItIsPreferred() {
        let cloud = HomeCloudChiefs(hosted: Self.hosted, placed: Self.placed)
        #expect(cloud.chiefTab(local: Self.local, localHasHistory: false, choice: .hosted, prefersLocal: true) == Self.local)
        #expect(cloud.chiefTab(local: Self.local, localHasHistory: true, choice: .placed, prefersLocal: true) == Self.local)
        #expect(cloud.chiefTab(local: Self.local, localHasHistory: true, choice: .hosted, prefersLocal: false) == "conv_hosted")
        // Before this Mac's owner lists its Chief the tab waits: the person's choice never opens
        // the cloud Chief's composer, whose messages would leave this Mac.
        #expect(cloud.chiefTab(local: nil, localHasHistory: false, choice: .hosted, prefersLocal: true) == nil)
        #expect(cloud.chiefTab(local: nil, localHasHistory: true, choice: .placed, prefersLocal: true) == nil)
    }

    @Test func thisMacsChiefIsMainWhenItIsPreferred() {
        let rows = HomeChiefRosterTests.rows
        let roster = HomeChiefRoster.make(rows: rows, local: HomeChiefRosterTests.local, hosted: HomeChiefRosterTests.hosted,
                                          placed: HomeChiefRosterTests.placed, server: "cmux20", showsPlaced: true, prefersLocal: true)
        #expect(roster.main == HomeChiefRosterTests.local)
        // Every Chief still says where it runs.
        #expect(roster.places[HomeChiefRosterTests.hosted] == .cloud)
        #expect(roster.places[HomeChiefRosterTests.placed] == .server("cmux20"))
        #expect(roster.tag(for: HomeChiefRosterTests.local, engine: nil)
            == HomeConversationStrings.mainChief + " \u{00B7} " + HomeConversationStrings.placeThisMac)
    }

    /// A failed cloud read leaves `cloudChiefsRead` false for the whole launch, so the last
    /// launch's cached Main is applied the whole time. With This Mac picked and its Chief listed,
    /// that cached cloud Main must not take Main back (review of #23984).
    @Test func thisMacsMainSurvivesACachedCloudMainFromTheLastLaunch() {
        let rows = HomeChiefRosterTests.rows
        let live = HomeChiefRoster.make(rows: rows, local: HomeChiefRosterTests.local, hosted: HomeChiefRosterTests.hosted,
                                        placed: HomeChiefRosterTests.placed, server: "cmux20", showsPlaced: false,
                                        prefersLocal: true)
        #expect(live.main == HomeChiefRosterTests.local, "This Mac is picked and its Chief is listed")
        // The last launch ran on the Hosted Chief, and its roster is still the cache.
        let last = HomeChiefRoster(main: HomeChiefRosterTests.hosted,
                                   places: [HomeChiefRosterTests.hosted: .cloud,
                                            HomeChiefRosterTests.placed: .server("cmux20")])
        #expect(live.launching(last: last, keepsMain: true).main == HomeChiefRosterTests.local,
                "the cached cloud Main does not take Main back from This Mac")
        // Its places still come from the cache, so the first frame does not mistag them.
        #expect(live.launching(last: last, keepsMain: true).places[HomeChiefRosterTests.placed] == .server("cmux20"))
        // Without the current pick, the cache still leads, as it did before.
        #expect(live.launching(last: last).main == HomeChiefRosterTests.hosted)
    }

    // MARK: Home's pick

    @Test func autoPicksThisMacsChiefWhileItsBrainRunsElseHosted() {
        let home = Self.services().home
        home.setCloudChiefs(HomeCloudChiefs(hosted: Self.hosted))
        home.localChiefRunning = false
        #expect(!home.prefersLocalChief)
        #expect(home.cloudChief == Self.hosted, "no optchat-chief on this Mac: the Hosted Chief")
        home.localChiefRunning = true
        #expect(home.prefersLocalChief)
        #expect(home.cloudChief == nil, "this Mac's optchat-chief runs: this Mac's Chief")
    }

    /// With This Mac chosen and its conversation not listed yet, the page's fallback skips the
    /// cloud Chiefs instead of opening one (review of #23984): the choice is about where the
    /// person's Chief messages go, so no fallback may send them to the cloud.
    @Test func thisMacsChoiceExcludesEveryCloudChiefFromThePagesFallback() async throws {
        let services = Self.services()
        let home = services.home
        home.setCloudChiefs(HomeCloudChiefs(hosted: Self.hosted, placed: Self.placed))
        home.localChiefRunning = false
        #expect(home.excludedChiefConversations.isEmpty, "Auto with no local brain: the cloud Chief is the default")

        let (settings, url) = try await Self.settings(#"{"home":{"chiefEngine":"local"}}"#)
        services.settings = settings
        #expect(home.excludedChiefConversations == ["conv_hosted", "conv_placed"])
        #expect(home.defaultChiefConversation == nil, "this Mac's conversation is not listed: the tab waits")

        try Data(#"{"home":{"chiefEngine":"hosted"}}"#.utf8).write(to: url)
        await settings.reload()
        #expect(home.excludedChiefConversations.isEmpty, "Hosted: the cloud Chief is the point")
    }

    /// The page's own fallback, not only the excluded set: with This Mac chosen it opens the first
    /// conversation that is not a cloud Chief's, even when a cloud Chief leads the list (review of
    /// #23984: the test above passes with the page's filtering removed).
    @Test func thePagesFallbackOpensThisMacsChiefWhileACloudChiefLeadsTheList() async throws {
        let services = Self.services()
        let home = services.home
        home.setCloudChiefs(HomeCloudChiefs(hosted: Self.hosted, placed: Self.placed))
        // The Hosted Chief is the newest, so it is the list's first row and the fallback's first pick.
        let rows = Self.cloudLedRows
        #expect(TopHomePageView.defaultConversation(rows: rows, home: home)?.rawValue == "conv_hosted",
                "Auto with no local brain: the Hosted Chief is both the default and the first row")

        services.settings = try await Self.settings(#"{"home":{"chiefEngine":"local"}}"#).0
        #expect(home.defaultChiefConversation == nil, "this Mac's conversation is not listed: there is no Chief to open")
        #expect(TopHomePageView.defaultConversation(rows: rows, home: home)?.rawValue == "conv_local",
                "the fallback skips both cloud Chiefs and opens this Mac's conversation")
    }

    /// Switching to This Mac while its Chief is not listed yet leaves the cloud Chief on screen:
    /// there is no Chief conversation to replace it with, so the page falls back to one the Engine
    /// row allows (review of #23984).
    @Test func pickingThisMacLeavesTheCloudChiefOnScreen() async throws {
        let services = Self.services()
        let home = services.home
        home.setCloudChiefs(HomeCloudChiefs(hosted: Self.hosted, placed: Self.placed))
        let rows = Self.cloudLedRows
        let hosted = CmuxHomeCore.ConversationID("conv_hosted")
        #expect(TopHomePageView.replacementForExcluded(shown: hosted, rows: rows, home: home) == nil,
                "Auto with no local brain: the Hosted Chief is the choice, so it stays")

        services.settings = try await Self.settings(#"{"home":{"chiefEngine":"local"}}"#).0
        #expect(TopHomePageView.replacementForExcluded(shown: hosted, rows: rows, home: home)?.rawValue == "conv_local")
        // What the row allows is already shown, or nothing is: the page leaves it alone.
        #expect(TopHomePageView.replacementForExcluded(shown: CmuxHomeCore.ConversationID("conv_local"),
                                                       rows: rows, home: home) == nil)
        #expect(TopHomePageView.replacementForExcluded(shown: nil, rows: rows, home: home) == nil)
    }

    /// Picking This Mac goes through a stretch with no Chief at all (its conversation is not listed
    /// yet), and the Chief that arrives after it must still open: the page follows the Chief it
    /// opened itself across that stretch (review of #23984, finding 1).
    @Test func theChiefThatArrivesAfterPickingThisMacStillOpens() async throws {
        let services = Self.services()
        let home = services.home
        home.setCloudChiefs(HomeCloudChiefs(hosted: Self.hosted, placed: Self.placed))
        services.settings = try await Self.settings(#"{"home":{"chiefEngine":"local"}}"#).0
        let hosted = CmuxHomeCore.ConversationID("conv_hosted")

        // Nothing the row allows is listed, so the Hosted Chief stays on screen for now.
        let cloudOnly = [HomeChiefRosterTests.chief(HomeChiefRosterTests.hosted, "chief_hosted", "Chief", at: 5),
                         HomeChiefRosterTests.chief(HomeChiefRosterTests.placed, "chief_placed", "Chief", at: 4)]
        let waiting = TopHomePageView.followUp(chief: nil, shown: hosted, followed: "conv_hosted", composing: false,
                                               rows: cloudOnly, home: home)
        #expect(waiting == .init(open: nil, followed: "conv_hosted"))
        // This Mac's Chief is listed: it opens, because the page still follows what it opened.
        #expect(TopHomePageView.followUp(chief: "conv_local", shown: hosted, followed: waiting.followed, composing: false,
                                         rows: Self.cloudLedRows, home: home).open?.rawValue == "conv_local")

        // With a DM listed the page leaves the Hosted Chief for it, and follows the DM, so this
        // Mac's Chief replaces that too once it arrives.
        let withDM = cloudOnly + [HomeChiefRosterTests.dm(HomeChiefRosterTests.ada, at: 1)]
        let moved = TopHomePageView.followUp(chief: nil, shown: hosted, followed: "conv_hosted", composing: false,
                                             rows: withDM, home: home)
        #expect(moved == .init(open: HomeChiefRosterTests.ada, followed: "conv_ada"))
        #expect(TopHomePageView.followUp(chief: "conv_local", shown: HomeChiefRosterTests.ada, followed: moved.followed,
                                         composing: false, rows: Self.cloudLedRows, home: home).open?.rawValue == "conv_local")

        // What the person opened themselves is never replaced, by a Chief or by this stretch.
        #expect(TopHomePageView.followUp(chief: "conv_local", shown: HomeChiefRosterTests.ada, followed: "conv_hosted",
                                         composing: false, rows: Self.cloudLedRows, home: home).open == nil)
        // Not even when what they opened is a cloud Chief the row excludes: the page followed the
        // Hosted Chief, they opened the placed one, and this stretch leaves it where it is.
        #expect(TopHomePageView.followUp(chief: nil, shown: HomeChiefRosterTests.placed, followed: "conv_hosted",
                                         composing: false, rows: withDM, home: home)
            == .init(open: nil, followed: "conv_hosted"))
    }

    /// A conversation the person opens is not one the page follows, so a Chief that arrives later
    /// never takes them off it — not even the conversation the page's own first fallback had
    /// opened, which they may come back to (review of #23984, finding 1).
    @Test func openingAConversationEndsWhatThePageFollows() async throws {
        let services = Self.services()
        services.home.setCloudChiefs(HomeCloudChiefs(hosted: Self.hosted))
        let page = TopHomePageView(services: services, windowKey: { "chief-follow" })
        #expect(page.followedChief == "conv_hosted", "the page follows the Chief it would open itself")
        page.show(CmuxHomeCore.ConversationID("conv_ada"))
        #expect(page.followedChief == nil, "the person opened one: the page follows nothing now")
    }

    /// Auto's own sequence: the person opens the Hosted Chief while this Mac's brain runs, that
    /// brain dies (so Hosted is preferred, and nothing opens because they are already there), and
    /// its restart must not take them back to this Mac's Chief. The page follows only what it
    /// opened itself, so a Chief it left them alone for is not one it may replace later (review of
    /// #23984, finding 1).
    @Test func aPreferredChiefThePageDidNotOpenIsNotFollowed() async throws {
        let services = Self.services()
        let home = services.home
        home.setCloudChiefs(HomeCloudChiefs(hosted: Self.hosted, placed: Self.placed))
        let rows = Self.cloudLedRows
        let hosted = CmuxHomeCore.ConversationID("conv_hosted")
        // They opened the Hosted Chief themselves, so the page follows nothing.
        let died = TopHomePageView.followUp(chief: "conv_hosted", shown: hosted, followed: nil, composing: false,
                                            rows: rows, home: home)
        #expect(died == .init(open: nil, followed: nil), "nothing opens: they are already there")
        // The brain is back, so this Mac's Chief is preferred again; they stay where they are.
        #expect(TopHomePageView.followUp(chief: "conv_local", shown: hosted, followed: died.followed, composing: false,
                                         rows: rows, home: home) == .init(open: nil, followed: nil))
    }

    /// The Engine row is watched, not only the preferred Chief's id: before the cloud read lands
    /// and with this Mac's Chief not listed, there is no Chief to open either side of the change,
    /// so a page that watched the id alone would never reconcile what it had opened by itself
    /// (review of #23984, finding 1).
    @Test func theEngineRowIsWatchedEvenWhileThereIsNoChiefToOpen() async throws {
        let services = Self.services()
        let home = services.home
        // No cloud Chief read yet, and this Mac's Chief is not listed.
        #expect(home.defaultChiefConversation == nil)
        #expect(TopHomePageView.chiefKey(home) == .init(chief: nil, prefersLocal: false))

        services.settings = try await Self.settings(#"{"home":{"chiefEngine":"local"}}"#).0
        #expect(home.defaultChiefConversation == nil, "still no Chief to open: the id did not change")
        #expect(TopHomePageView.chiefKey(home) == .init(chief: nil, prefersLocal: true),
                "but what the page watches did, so it reconciles what it opened")
    }

    /// The New Message page is never closed by the Engine row: `show(_:)` would leave it, dropping
    /// an empty compose page and hiding a written one (review of #23984, finding 2).
    @Test func pickingThisMacNeverClosesTheNewMessagePage() async throws {
        let services = Self.services()
        let home = services.home
        home.setCloudChiefs(HomeCloudChiefs(hosted: Self.hosted, placed: Self.placed))
        services.settings = try await Self.settings(#"{"home":{"chiefEngine":"local"}}"#).0
        let hosted = CmuxHomeCore.ConversationID("conv_hosted")
        #expect(TopHomePageView.followUp(chief: nil, shown: hosted, followed: "conv_hosted", composing: true,
                                         rows: Self.cloudLedRows, home: home) == .init(open: nil, followed: "conv_hosted"),
                "a conversation the row allows is listed, but the New Message page is up")
        #expect(TopHomePageView.followUp(chief: nil, shown: hosted, followed: "conv_hosted", composing: false,
                                         rows: Self.cloudLedRows, home: home).open?.rawValue == "conv_local",
                "with no New Message page it moves, so the test above fails for its own reason")
        // Nor when this Mac's Chief arrives while the page is still being written on. The page did
        // not open that Chief, so it does not follow it either: what it was following stays, and
        // the Chief replaces that when the person leaves New Message and it is shown again.
        #expect(TopHomePageView.followUp(chief: "conv_local", shown: hosted, followed: "conv_hosted", composing: true,
                                         rows: Self.cloudLedRows, home: home) == .init(open: nil, followed: "conv_hosted"))
        #expect(TopHomePageView.followUp(chief: "conv_local", shown: hosted, followed: "conv_hosted", composing: false,
                                         rows: Self.cloudLedRows, home: home).open?.rawValue == "conv_local")
    }

    /// Two readers of this Mac's brain liveness (a brain that started or died, and the Chief tab
    /// check) each suspend across the other's whole read, and the older answer must never land on
    /// top of the newer one: that would leave Auto on the wrong Chief for the rest of the launch
    /// (review of #23984, finding 2).
    @Test func anOlderLivenessReadNeverOverwritesANewerOne() {
        // The tab check's read is #1 and suspends; the brain change's #2 starts and publishes.
        #expect(HomeService.publishes(read: 2, published: 0), "the newer read publishes")
        // Read #1 resumes with its stale answer: it is older than what is published, so it does not.
        #expect(!HomeService.publishes(read: 1, published: 2))
        // The next read of either caller is newer than anything published, so it does.
        #expect(HomeService.publishes(read: 3, published: 2))
        // And a read never publishes twice (``readLocalChiefRunning`` sets `published` to its own).
        #expect(!HomeService.publishes(read: 3, published: 3))
    }

    @Test func theEngineSettingForcesEitherChief() async throws {
        let services = Self.services()
        let home = services.home
        home.setCloudChiefs(HomeCloudChiefs(hosted: Self.hosted))
        let (settings, url) = try await Self.settings(#"{"home":{"chiefEngine":"local"}}"#)
        services.settings = settings
        home.localChiefRunning = false
        #expect(home.cloudChief == nil, "This Mac: this Mac's Chief even while its brain is not running")

        try Data(#"{"home":{"chiefEngine":"hosted"}}"#.utf8).write(to: url)
        await settings.reload()
        home.localChiefRunning = true
        #expect(home.cloudChief == Self.hosted, "Hosted: the cloud Chief even while this Mac's brain runs")

        try Data("{}".utf8).write(to: url)
        await settings.reload()
        #expect(home.cloudChief == nil, "Auto again: this Mac's brain runs, so this Mac's Chief")
    }

    /// A list a cloud Chief leads: the Hosted Chief, the placed one, then this Mac's, then a DM.
    /// Every Chief is in the Chiefs section in this order, so the first row is a cloud Chief's.
    static var cloudLedRows: [InboxRow] {
        [HomeChiefRosterTests.chief(HomeChiefRosterTests.hosted, "chief_hosted", "Chief", at: 5),
         HomeChiefRosterTests.chief(HomeChiefRosterTests.placed, "chief_placed", "Chief", at: 4),
         HomeChiefRosterTests.chief(HomeChiefRosterTests.local, "agent_mux", "Chief", at: 3),
         HomeChiefRosterTests.dm(HomeChiefRosterTests.ada, at: 1)]
    }

    static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    static func settings(_ json: String) async throws -> (SettingsController, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-chief-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        return (settings, url)
    }
}
