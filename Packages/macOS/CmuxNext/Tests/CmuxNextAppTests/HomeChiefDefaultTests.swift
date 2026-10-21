import AppKit
import CmuxHomeCore
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextHome
import CmuxNextHostedChief
import Testing

/// The default Chief (#64, 2026-10-21): this Mac's Chief while this Mac's optchat-chief runs, the
/// Hosted (cloud) Chief otherwise. Debug Settings' "Default Chief" can force either one.
@MainActor @Suite(.serialized)
struct HomeChiefDefaultTests {
    static let local = "conv_local"
    static let hosted = CloudChief(id: "chief_hosted", displayName: "Chief", isDefault: true, mainConversation: "conv_hosted", rev: 1)
    static let placed = CloudChief(id: "chief_placed", displayName: "Chief", isDefault: false, mainConversation: "conv_placed", rev: 1,
                                   brainPlace: .init(host: "host_mini", install: "install_1"))

    // MARK: The choice

    @Test func autoIsTheDefaultAndADebugChoice() {
        #expect(HomeTunables.chiefDefault.defaultValue == .auto)
        #expect(HomeTunables.chiefDefault.descriptor.key == "home.chiefDefault")
        #expect(HomeTunables.all.contains { $0.key == "home.chiefDefault" })
        #expect(HomeChiefDefault.allCases == [.auto, .local, .hosted])
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
        // Before this Mac's owner lists its Chief, the cloud Chief keeps the tab.
        #expect(cloud.chiefTab(local: nil, localHasHistory: false, choice: .hosted, prefersLocal: true) == "conv_hosted")
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

    @Test func theDebugChoiceForcesEitherChief() throws {
        let home = Self.services().home
        home.setCloudChiefs(HomeCloudChiefs(hosted: Self.hosted))
        let store = TunableStore.shared
        store.activate(file: nil)
        store.register(HomeTunables.all)
        defer { store.set(HomeTunables.chiefDefault.key, nil) }

        try #require(store.set(HomeTunables.chiefDefault.key, .choice("local")) == .choice("local"))
        home.localChiefRunning = false
        #expect(home.cloudChief == nil, "Local: this Mac's Chief even while its brain is not running")

        try #require(store.set(HomeTunables.chiefDefault.key, .choice("hosted")) == .choice("hosted"))
        home.localChiefRunning = true
        #expect(home.cloudChief == Self.hosted, "Hosted: the cloud Chief even while this Mac's brain runs")
    }

    static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }
}
