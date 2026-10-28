import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Testing

/// HomeService's own observations and waits (plans/cmux-next/chrome-parity/
/// p06-scheduler.md rules 3 and 9): its loops are `ServiceObservation`s, so their side effects run
/// while no Home view exists, and `awaitHomeEnsured` is a keyed wait that only the latest
/// `ensure_home` settles.
@MainActor @Suite(.serialized) struct HomeServiceObservationTests {
    /// The Chief owner connects while no Home shows: the list is read from it all the same (the
    /// owner observation's side effect), as the conversation-tab Home it feeds is not on screen.
    @Test func theChiefOwnerConnectingReloadsTheListWithNoHomeShown() async {
        let services = Self.services()
        let home = services.home
        home.watchChiefOwner()
        #expect(home.tabViews.isEmpty, "a Home view exists")
        let before = home.listGeneration
        // Never started: a request on it fails at once, and no socket is touched.
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/nonexistent/cmux-home-owner-test.sock"))
        home.chief.attach(connection, identity: DaemonIdentity(capabilities: [DaemonCapability.localConversations.rawValue], generation: "owner"))
        let reloaded = await HomeDaemonNoticeTests.wait { home.listGeneration > before }
        #expect(reloaded, "the owner's connection read no list while no Home showed")
        await HomeDaemonNoticeTests.settle()
        #expect(home.listGeneration == before + 1, "one owner connection read the list \(home.listGeneration - before) times")
    }

    /// Two `ensure_home`s overlap: the older one answering does not end the wait (its in-flight flag
    /// belongs to the newer one), and the newer one answering does. `FirstWorkspaceLaunch` waits on it.
    @Test func onlyTheLatestEnsureHomeEndsTheWait() async {
        let services = Self.services()
        let home = services.home
        let first = home.beginHomeEnsure()
        let waiter = Task { @MainActor in await home.awaitHomeEnsured() }
        await home.homeEnsureWaiters.untilPending(1)
        let second = home.beginHomeEnsure()

        home.settleHomeEnsure(first)
        await drainMainTurns()
        #expect(home.homeEnsureInFlight, "the older ensure_home cleared the newer one's flag")
        #expect(home.homeEnsureWaiters.pendingCount == 1, "the older ensure_home ended the wait")

        home.settleHomeEnsure(second)
        await waiter.value
        #expect(!home.homeEnsureInFlight)
        #expect(home.homeEnsureWaiters.pendingCount == 0)
    }

    /// No `ensure_home` in flight: the wait returns at once.
    @Test func noEnsureHomeInFlightReturnsAtOnce() async {
        let home = Self.services().home
        await home.awaitHomeEnsured()
        #expect(home.homeEnsureWaiters.pendingCount == 0)
    }

    static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }
}

/// `ensureChiefTab` no longer waits for the Chief owner itself: with no owner it stops, and the
/// owner's first connection (``HomeService/watchChiefOwner()``) runs `ensure_home` again, once, which
/// then finds or creates the local Chief conversation in that owner.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct HomeChiefOwnerLateTests {
    @Test func theOwnerConnectingAfterEnsureHomeChecksTheChiefTabOnce() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let home = services.home
            home.watchChiefOwner()
            home.ensureHomeWorkspace(connection)
            let waiting = "waiting for the chief owner"
            try await PasswordManagerRouteTests.until({ home.homeWorkspaceStep.hasPrefix(waiting) }, within: .seconds(60),
                                                       report: { home.homeWorkspaceStep })
            let generation = home.homeEnsureGeneration
            // The harness's daemon serves local conversations: it stands in for the Chief owner.
            home.chief.attach(connection, identity: DaemonIdentity(capabilities: [DaemonCapability.localConversations.rawValue],
                                                                   generation: "owner"))
            try await PasswordManagerRouteTests.until({ home.homeEnsureGeneration > generation }, report: { home.homeWorkspaceStep })
            await home.homeWorkspaceTask?.value
            await HomeDaemonNoticeTests.settle()
            #expect(home.homeEnsureGeneration == generation + 1,
                    "the owner's connection ran ensure_home \(home.homeEnsureGeneration - generation) times")
            #expect(!home.homeWorkspaceStep.hasPrefix(waiting), "the Chief tab still waits with the owner connected")
            #expect(!home.homeWorkspaceStep.hasPrefix("failed"), "the Chief tab check failed: \(home.homeWorkspaceStep)")
            let list = try await CmuxNextDaemon.ConversationClient(connection).list()
            let chiefs = list.filter { $0.participants.contains { $0.id == HomeChiefName.muxID } }
            #expect(chiefs.count == 1, "the owner has \(chiefs.count) Chief conversations after the check")
        }
    }
}
