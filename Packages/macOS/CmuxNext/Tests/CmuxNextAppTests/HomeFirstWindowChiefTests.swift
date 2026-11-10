import AppKit
@testable import CmuxNextApp
import CmuxHomeCore
import CmuxNextHomeEngine
import CmuxNextWakeupsTestSupport
import Foundation
import Observation
import Testing

/// A fresh profile's first window is Home's Messages page, which must open the Chief chat (where the
/// Set Up cmux card lives) as soon as this build's Chief owner is up. The page reaches its
/// conversations only through `cmux.host.credential.load`, which needs the owner's endpoint: the
/// owner a first launch spawns is still starting when the page loads. The call answered "starting"
/// at once, and the page's doubling retry delays kept it blank for seconds after the owner was up
/// (onboarding walk fresh/first-window, red from the nightly at 824dfe557cb2). The wait now answers
/// on the owner's connection, and a Chief that is listed only after the page's first report opens.
@MainActor @Suite(.serialized)
struct HomeFirstWindowChiefTests {
    @Observable @MainActor
    final class Owner {
        var connected = false
    }

    /// The credential call answers the moment a starting owner connects, not at the deadline or a
    /// retry: the clock never moves, so only the connection can end the wait.
    @Test func theCredentialWaitAnswersWhenTheStartingOwnerConnects() async throws {
        let owner = Owner()
        let clock = ManualClock()
        // task-owner: the test's one wait; awaited below
        let wait = Task { @MainActor in await OwnerStartWait(limit: .seconds(15), clock: clock).holds { owner.connected } }
        try await clock.waitForSleeper()
        owner.connected = true
        #expect(await wait.value, "the owner connected within the wait: the page gets its endpoint now")
    }

    /// An owner that never connects ends the wait at its deadline, and the page's own retries take over.
    @Test func anOwnerThatNeverConnectsEndsTheWaitAtItsDeadline() async throws {
        let owner = Owner()
        let clock = ManualClock()
        // task-owner: the test's one wait; awaited below
        let wait = Task { @MainActor in await OwnerStartWait(limit: .seconds(15), clock: clock).holds { owner.connected } }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(15))
        #expect(await wait.value == false)
    }

    /// A connected owner is not waited for.
    @Test func aConnectedOwnerAnswersAtOnce() async {
        let owner = Owner()
        owner.connected = true
        #expect(await OwnerStartWait(limit: .seconds(15), clock: ManualClock()).holds { owner.connected })
    }

    /// Fresh profile, signed out: no Chief and no rows when the page first reports nothing shown, so
    /// nothing opens; this Mac's Chief, listed next, is what the page opens by itself (the rows watch).
    @Test func aFreshProfilesChiefOpensOnceItIsListed() {
        let services = HomeChiefDefaultTests.services()
        let home = services.home
        #expect(HomeDefaultConversation.afterShown(nil, composing: false, followed: nil, rows: [], home: home)
            == .init(open: nil, followed: nil), "nothing listed yet: nothing to open")
        let rows = [HomeChiefRosterTests.chief(HomeChiefRosterTests.local, "agent_mux", "Chief", at: 1)]
        #expect(HomeDefaultConversation.defaultConversation(rows: rows, home: home)?.rawValue == "conv_local",
                "the Chief listed after the first report is the page's default")
        #expect(HomeDefaultConversation.afterShown(nil, composing: false, followed: nil, rows: rows, home: home).open?.rawValue == "conv_local",
                "listed before the first report: the first report opens it")
    }
}
