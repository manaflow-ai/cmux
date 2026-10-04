import CmuxHomeCore
import CmuxNextDaemon
import Foundation
import os
import Testing
@testable import CmuxNextApp

/// The account the cloud source acts as is the account the daemon's lease
/// holds (home-cloud-proxy.md section 2), whatever the observed sign-in
/// state says while a lease is in flight or failed.
@Suite(.timeLimit(.minutes(1))) struct HomeCloudLinkTests {
    typealias F = CloudFixtures
    let theirs = "conv_dm_01J0000000000000000000000A"
    let opened = "conv_dm_01J0000000000000000000000B"

    func make(clock: ManualClock = ManualClock()) -> (HomeCloudLink, CloudHomeSource, FakeTokens) {
        let tokens = FakeTokens()
        let lease = HomeCloudLease(tokens: tokens, apiBaseURL: URL(string: "https://cloud-api.test")!, clientVersion: nil,
                                   logger: Logger(subsystem: "cmux-next-tests", category: "lease"))
        let source = CloudHomeSource(me: Participant(id: F.localMe, kind: .human, displayName: "Me"))
        return (HomeCloudLink(lease: lease, source: source, localID: F.localMe, clock: clock), source, tokens)
    }

    nonisolated static func refused(_ cmd: String) -> DaemonError {
        .command(cmd: cmd, message: "unauthenticated", code: "cloud_unauthenticated",
                 details: .object(["reason": .string("unauthenticated")]), retryable: true)
    }

    nonisolated static func ops(_ calls: [FakeCloudDaemon.Call]) -> Int { calls.filter { if case .op = $0 { true } else { false } }.count }

    func link(_ daemon: FakeCloudDaemon, _ user: String?) -> HomeCloudLink.Link {
        HomeCloudLink.Link(endpoint: daemon, id: ObjectIdentifier(daemon), userID: user, displayName: user ?? "")
    }

    /// The switch from A to B fails to read B's token. The daemon must not
    /// keep A's lease while the source acts as B: B would see A's inbox and
    /// B's ops would commit as A.
    @Test func aTokenFailureOnASwitchNeverShowsTheInboxOrCommitsAnOpAsThePreviousAccount() async throws {
        let opened = opened
        let daemon = FakeCloudDaemon(.init(heads: [theirs: F.head(theirs)],
                                           op: { _ in CloudConversationOpResult(conversation: F.head(opened, rev: 1, lastSeq: 0)) },
                                           inboxBySubject: ["a": [F.entry(theirs)], "b": []]))
        let (linker, source, tokens) = make()
        tokens.user = "a"
        await linker.apply(link(daemon, "a"))
        #expect(try await source.inbox().conversations.map(\.id.rawValue) == [theirs])

        tokens.user = "b"
        tokens.failing = ["b"]
        await linker.apply(link(daemon, "b"))
        _ = try? await source.inbox()
        #expect(!source.currentInbox().conversations.contains { $0.id.rawValue == theirs }, "A's inbox shown as B's")
        _ = try? await source.submit(HomeIntent(key: IdempotencyKey("cmk_b"), op: .invite(contact: .email("z@y.com"))))
        #expect(!daemon.sentOps.contains { $0.subject == "a" }, "committed as A: \(daemon.sentOps)")

        // B's token reads again: the daemon's next request leases B, and B's ops go out as B.
        tokens.failing = []
        linker.sessionNeeded(reason: "missing")
        await linker.settle()
        _ = try? await source.submit(HomeIntent(key: IdempotencyKey("cmk_b2"), op: .invite(contact: .email("z@y.com"))))
        #expect(daemon.sentOps.filter { $0.key == "cmk_b2" }.map(\.subject) == ["b"])
    }

    /// The daemon reconnects while the user switches from A to B: the lease
    /// for the reconnect reads B's token, and the new connection asks for a
    /// lease. A's unconfirmed intent must never go out under B's lease.
    @Test func aReconnectRacingASwitchNeverSendsThePreviousAccountsIntentUnderTheNextLease() async throws {
        let opened = opened
        let first = FakeCloudDaemon(.init(op: { _ in throw F.unavailable() }))
        let (linker, source, tokens) = make()
        tokens.user = "a"
        await linker.apply(link(first, "a"))
        let start = HomeIntent(key: IdempotencyKey("cmk_a"),
                               op: .startConversation(contacts: [.email("x@y.com")], firstMessage: [.text("hello")]))
        await #expect(throws: HomeRejection.indeterminate) { try await source.submit(start) }

        let second = FakeCloudDaemon(.init(op: { _ in CloudConversationOpResult(conversation: F.head(opened, rev: 1, lastSeq: 0)) }))
        let gate = Gate()
        tokens.gate = gate
        let reconnect = Task { await linker.apply(link(second, "a")) }
        await gate.arrived()
        tokens.user = "b"
        linker.sessionNeeded(reason: "missing")
        gate.open()
        await reconnect.value
        await linker.settle()
        // The store resends it after a recovery; here it is resent at once.
        _ = try? await source.submit(start)
        #expect(!second.sentOps.contains { $0.key.hasPrefix("cmk_a") && $0.subject != "a" }, "sent under another lease: \(second.sentOps)")
    }

    /// The lease fails at sign-in, and the daemon's one `missing` request
    /// fails too. An op refused while there is no lease must ask for one:
    /// the daemon asks only when a command reaches it, and none does.
    @Test func anOpRefusedForAMissingLeaseLeasesAgainAfterAFailedRenew() async throws {
        let opened = opened
        let daemon = FakeCloudDaemon(.init(op: { _ in CloudConversationOpResult(conversation: F.head(opened, rev: 1, lastSeq: 0)) }))
        let (linker, source, tokens) = make()
        tokens.user = "a"
        tokens.failing = ["a"]
        await linker.apply(link(daemon, "a"))
        linker.sessionNeeded(reason: "missing")
        await linker.settle()
        #expect(!daemon.calls.contains(.setSession("a")))

        tokens.failing = []
        let invite = HomeIntent(key: IdempotencyKey("cmk_a"), op: .invite(contact: .email("z@y.com")))
        await #expect(throws: HomeRejection.ownerUnreachable) { try await source.submit(invite) }
        #expect(await daemon.wait { $0.contains(.setSession("a")) }, "no lease after a refused op: \(daemon.calls)")
        await linker.settle()
        _ = try await source.submit(invite)
        #expect(daemon.sentOps.map(\.subject) == ["a"])
    }

    /// A new display name is the same account: the lease is not taken
    /// again, so a token read failing at that moment never ends a good lease.
    @Test func aNewDisplayNameKeepsTheLease() async throws {
        let opened = opened
        let daemon = FakeCloudDaemon(.init(op: { _ in CloudConversationOpResult(conversation: F.head(opened, rev: 1, lastSeq: 0)) }))
        let (linker, source, tokens) = make()
        tokens.user = "a"
        await linker.apply(link(daemon, "a"))
        tokens.failing = ["a"]
        await linker.apply(HomeCloudLink.Link(endpoint: daemon, id: ObjectIdentifier(daemon), userID: "a", displayName: "A Renamed"))
        await linker.settle()
        #expect(daemon.calls.filter { if case .setSession = $0 { true } else { false } } == [.setSession("a")])
        #expect(!daemon.calls.contains(.clearSession))
        _ = try await source.submit(HomeIntent(key: IdempotencyKey("cmk_n"), op: .invite(contact: .email("z@y.com"))))
        #expect(daemon.sentOps.map(\.subject) == ["a"])
    }

    /// A token without a `sub` claim names no account: it is never leased,
    /// and the daemon's lease is cleared.
    @Test func aTokenWithoutASubjectIsNeverLeased() async throws {
        let daemon = FakeCloudDaemon()
        let tokens = FakeTokens()
        tokens.user = "a"
        tokens.withoutSubject = true
        let lease = HomeCloudLease(tokens: tokens, apiBaseURL: URL(string: "https://cloud-api.test")!, clientVersion: nil,
                                   logger: Logger(subsystem: "cmux-next-tests", category: "lease"))
        #expect(await lease.sync(daemon, expectedUserID: "a") == .failed)
        #expect(daemon.calls == [.clearSession])
    }

    /// A failed lease is tried again after a backoff, with no op or daemon
    /// request needed, until it holds; then the account's ops go out.
    @Test func aFailedLeaseIsRetriedAfterABackoffUntilItHolds() async throws {
        let clock = ManualClock()
        let opened = opened
        let daemon = FakeCloudDaemon(.init(op: { _ in CloudConversationOpResult(conversation: F.head(opened, rev: 1, lastSeq: 0)) }))
        let (linker, source, tokens) = make(clock: clock)
        tokens.user = "a"
        tokens.failing = ["a"]
        await linker.apply(link(daemon, "a"))
        await clock.sleepers(atLeast: 1)
        // The first retry fails too; the next waits twice as long.
        clock.advance(by: HomeCloudLink.firstRetry)
        await clock.sleepers(atLeast: 1)
        #expect(!daemon.calls.contains(.setSession("a")))

        tokens.failing = []
        clock.advance(by: HomeCloudLink.firstRetry * 2)
        #expect(await daemon.wait { $0.contains(.setSession("a")) })
        await linker.settle()
        _ = try await source.submit(HomeIntent(key: IdempotencyKey("cmk_r"), op: .invite(contact: .email("z@y.com"))))
        #expect(daemon.sentOps.map(\.subject) == ["a"])
    }

    /// Every upstream socket refused with the same token asks for a lease
    /// (the inbox and up to 64 conversations). One renewal answers them all:
    /// requests that wait for it join it, and a late one for the lease it
    /// replaced is already answered.
    @Test func manySocketsRefusedTogetherRenewTheLeaseOnce() async throws {
        let daemon = FakeCloudDaemon()
        let (linker, _, tokens) = make()
        tokens.user = "a"
        await linker.apply(link(daemon, "a"))
        let refused = try #require(daemon.leaseExpiry)
        for _ in 0..<65 { linker.sessionNeeded(reason: "unauthenticated", expiresAt: refused) }
        await linker.settle()
        #expect(daemon.leases == 2, "one refused token renewed \(daemon.leases - 1) times")
        #expect(daemon.leaseExpiry != refused)
        // Late requests for the replaced lease.
        for _ in 0..<65 { linker.sessionNeeded(reason: "unauthenticated", expiresAt: refused) }
        await linker.settle()
        #expect(daemon.leases == 2, "a request for a replaced lease renewed it again")
    }

    /// The Worker refuses every token (a dev backend on another Stack
    /// project, or clock skew). Each refused op asks for a lease and each
    /// renewal makes the store resend, so without a limit the two loop. A
    /// forced renewal soon after a successful one waits, longer each time,
    /// and only a reply or a live socket ends that wait.
    @Test func aWorkerThatRefusesEveryTokenRenewsAndResendsAtABoundedRate() async throws {
        let clock = ManualClock()
        let daemon = FakeCloudDaemon()
        let (linker, source, tokens) = make(clock: clock)
        tokens.user = "a"
        daemon.script.withLock { script in
            // Reads are refused too: a reply would show the Worker takes the token.
            script.inboxError = Self.refused("cloud-inbox-list")
            script.op = { [daemon] _ in
                // task-owner: one hop to the main actor, as the daemon's event does
                Task { @MainActor in linker.sessionNeeded(reason: "unauthenticated", expiresAt: daemon.leaseExpiry) }
                throw Self.refused("cloud-conversation-op")
            }
        }
        await linker.apply(link(daemon, "a"))
        // The store's part: each recovery resends the unconfirmed op.
        let intent = HomeIntent(key: IdempotencyKey("cmk_w"), op: .invite(contact: .email("z@y.com")))
        let stream = await source.events()
        // task-owner: the test's store stand-in; cancelled at the end
        let resender = Task {
            for await event in stream where event == .ownerRecovered { _ = try? await source.submit(intent) }
        }
        defer { resender.cancel() }
        _ = try? await source.submit(intent)
        // The op, one renewal, and the resend it recovers.
        #expect(await daemon.wait { Self.ops($0) >= 2 })
        for _ in 0..<2_000 { await Task.yield() }
        await linker.settle()
        try #require(daemon.leases == 2, "renewals looped: \(daemon.leases)")
        #expect(Self.ops(daemon.calls) == 2, "resends looped: \(Self.ops(daemon.calls))")

        // After the wait, one more renewal and one more resend; the next wait is longer.
        await clock.sleepers(atLeast: 1)
        clock.advance(by: HomeCloudLink.firstRetry)
        #expect(await daemon.wait { Self.ops($0) >= 3 })
        for _ in 0..<2_000 { await Task.yield() }
        await linker.settle()
        #expect(daemon.leases == 3)
        clock.advance(by: HomeCloudLink.firstRetry)
        for _ in 0..<2_000 { await Task.yield() }
        await linker.settle()
        #expect(daemon.leases == 3, "the wait did not grow")
        #expect(Self.ops(daemon.calls) == 3)
    }

    /// Another trusted local client set the daemon's lease (any client may
    /// send `cloud-session-set`). When that lease expires the daemon names
    /// its expiry, which this link never set: it renews anyway. Only a
    /// lease this link set and then replaced needs nothing.
    @Test func aLeaseAnotherLocalClientSetIsRenewedWhenItExpires() async throws {
        let daemon = FakeCloudDaemon()
        let (linker, _, tokens) = make()
        tokens.user = "a"
        await linker.apply(link(daemon, "a"))
        let ours = try #require(daemon.leaseExpiry)
        let theirs = ours + 777_000
        _ = try await daemon.setSession(CloudSessionSetRequest(apiBaseURL: "https://cloud-api.test",
                                                               accessToken: F.jwt(sub: "a"), expiresAt: theirs))
        #expect(daemon.leases == 2)
        linker.sessionNeeded(reason: "expired", expiresAt: theirs)
        await linker.settle()
        #expect(daemon.leases == 3, "an expired lease another client set was never renewed")
        // The lease this link set and that lease were both replaced: late requests for them need nothing.
        linker.sessionNeeded(reason: "expired", expiresAt: theirs)
        linker.sessionNeeded(reason: "expired", expiresAt: ours)
        await linker.settle()
        #expect(daemon.leases == 3)
    }

    /// A forced renewal waits while the cooldown after the last one runs.
    /// A reply on the current lease proves the Worker takes its token: the
    /// cooldown ends and the waiting renewal goes at once, instead of after
    /// a wait that can reach `maxRetry`.
    @Test func aProvenLeaseEndsTheCooldownAndSendsTheWaitingRenewal() async throws {
        let clock = ManualClock()
        let daemon = FakeCloudDaemon()
        let (linker, source, tokens) = make(clock: clock)
        tokens.user = "a"
        await linker.apply(link(daemon, "a"))
        linker.sessionNeeded(reason: "unauthenticated", expiresAt: daemon.leaseExpiry)
        await linker.settle()
        #expect(daemon.leases == 2)
        // The cooldown runs: this one waits.
        linker.sessionNeeded(reason: "expired", expiresAt: daemon.leaseExpiry)
        await linker.settle()
        #expect(daemon.leases == 2)
        // A reply on the renewed lease proves it.
        _ = try await source.inbox()
        #expect(await daemon.wait { calls in calls.filter { if case .setSession = $0 { true } else { false } }.count >= 3 },
                "the waiting renewal still waited for the cooldown")
    }

    /// One socket proves each new lease while another is refused under it
    /// (round-6 review, finding 4). The proof must not end the wait the
    /// same forced renewal started: forced renewals stay at least
    /// `firstRetry` apart instead of looping at round-trip speed.
    @Test func aProvenLeaseStillSpacesForcedRenewalsByTheFirstWait() async throws {
        let clock = ManualClock()
        let daemon = FakeCloudDaemon()
        let (linker, source, tokens) = make(clock: clock)
        tokens.user = "a"
        await linker.apply(link(daemon, "a"))
        linker.sessionNeeded(reason: "unauthenticated", expiresAt: daemon.leaseExpiry)
        await linker.settle()
        #expect(daemon.leases == 2)
        // A reply proves the renewed lease; another socket is refused under it right after.
        _ = try await source.inbox()
        for _ in 0..<2_000 { await Task.yield() }
        linker.sessionNeeded(reason: "unauthenticated", expiresAt: daemon.leaseExpiry)
        await linker.settle()
        for _ in 0..<2_000 { await Task.yield() }
        await linker.settle()
        #expect(daemon.leases == 2, "a proven lease let forced renewals go back to back: \(daemon.leases)")
        await clock.sleepers(atLeast: 1)
        clock.advance(by: HomeCloudLink.firstRetry)
        #expect(await daemon.wait { calls in calls.filter { if case .setSession = $0 { true } else { false } }.count >= 3 },
                "the waiting renewal never went")
    }

    /// The cooldown ends while other lease work runs: the renewal that
    /// waited for it is kept and goes once that work ends.
    @Test func aRenewalThatComesDueDuringLeaseWorkIsKept() async throws {
        let clock = ManualClock()
        let daemon = FakeCloudDaemon()
        let (linker, _, tokens) = make(clock: clock)
        tokens.user = "a"
        await linker.apply(link(daemon, "a"))
        linker.sessionNeeded(reason: "unauthenticated", expiresAt: daemon.leaseExpiry)
        await linker.settle()
        linker.sessionNeeded(reason: "expired", expiresAt: daemon.leaseExpiry)
        // Other lease work starts and holds on the token read.
        let gate = Gate()
        tokens.gate = gate
        linker.sessionNeeded(reason: "missing")
        await gate.arrived()
        await clock.sleepers(atLeast: 1)
        clock.advance(by: HomeCloudLink.firstRetry)
        for _ in 0..<2_000 { await Task.yield() }
        gate.open()
        await linker.settle()
        for _ in 0..<2_000 { await Task.yield() }
        await linker.settle()
        #expect(daemon.leases == 4, "the renewal that came due during other lease work was dropped: \(daemon.leases)")
    }

    /// A new link cancels the previous one's pending retry: no lease goes
    /// out for the account that left.
    @Test func aNewLinkCancelsThePendingRetry() async throws {
        let clock = ManualClock()
        let daemon = FakeCloudDaemon()
        let (linker, _, tokens) = make(clock: clock)
        tokens.user = "a"
        tokens.failing = ["a"]
        await linker.apply(link(daemon, "a"))
        await clock.sleepers(atLeast: 1)
        tokens.failing = []
        await linker.apply(HomeCloudLink.Link(endpoint: nil, id: nil, userID: "a", displayName: "a"))
        clock.advance(by: HomeCloudLink.maxRetry)
        for _ in 0..<2_000 { await Task.yield() }
        await linker.settle()
        #expect(!daemon.calls.contains(.setSession("a")), "a cancelled retry leased: \(daemon.calls)")
    }
}
