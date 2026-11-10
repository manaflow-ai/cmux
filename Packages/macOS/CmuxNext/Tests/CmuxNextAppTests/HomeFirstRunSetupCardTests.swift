import AppKit
@testable import CmuxHomeCore
@testable import CmuxNextApp
@testable import CmuxNextOnboarding
import Foundation
import Testing

/// A fresh profile's first window is Home with the Set Up cmux card in the Chief's chat (the onboarding probe's
/// `first_window()`: "Set Up cmux" with its agents, account and command line rows). It was last there at 85b09992;
/// #37736 moved the card into the React Messages page and #37777 deleted the native Home that hosted it, so the
/// nightly's fresh window showed only the "Did you know?" tip (first red 2026-11-10 12:34Z). The native Home is
/// back (#40611): a first run starts the card, and the Chief's Home shows it; any other conversation shows none.
@MainActor
struct HomeFirstRunSetupCardTests {
    static let chief = CmuxHomeCore.ConversationID("conv_first_run_chief")
    static let dm = CmuxHomeCore.ConversationID("conv_first_run_dm")

    @Test func aFreshProfilesHomeShowsTheSetUpCardInTheChiefChat() async throws {
        _ = NSApplication.shared
        let suite = "cmux-home-first-run-card-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let services = AppServices(environment: AppEnvironment.current([:]))
        let setup = FirstRunSetup(defaults: defaults)
        #expect(setup.route(isFirstRun: true, replacedKeys: ["cli.install.offeredAtLaunch"]) == .startCard,
                "a fresh profile starts the Set Up card")
        services.onboarding.setup = setup

        let store = services.home.homeStore
        let me = Participant(id: ParticipantID("me"), kind: .human, displayName: "Me")
        let date = Date(timeIntervalSince1970: 1_000)
        let chiefRow = ConversationSummary(id: Self.chief, title: "Chief", participants: [
            me, Participant(id: ParticipantID("agent_mux"), kind: .agent, displayName: "Chief", agentClass: .chief),
        ], createdAt: date, updatedAt: date)
        let dmRow = ConversationSummary(id: Self.dm, title: "Ada", participants: [
            me, Participant(id: ParticipantID("ada"), kind: .human, displayName: "Ada"),
        ], createdAt: date, updatedAt: date)
        _ = store.mirror.apply(inbox: InboxSnapshot(me: me, conversations: [chiefRow, dmRow], rev: 1))
        store.rebuildRows()

        let home = HomeHostView(services: services, conversation: Self.chief.rawValue)
        let other = HomeHostView(services: services, conversation: Self.dm.rawValue)
        for view in [home, other] { view.frame = NSRect(x: 0, y: 0, width: 600, height: 700) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !home.showsSetupCard, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(home.showsSetupCard, "a fresh profile's Chief Home shows no Set Up cmux card")
        #expect(!other.showsSetupCard, "the card shows only in the Chief's chat")

        // Hide ends it: the card leaves the Chief's chat.
        setup.end()
        let hideDeadline = ContinuousClock.now + .seconds(5)
        while home.showsSetupCard, ContinuousClock.now < hideDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!home.showsSetupCard)
    }
}
