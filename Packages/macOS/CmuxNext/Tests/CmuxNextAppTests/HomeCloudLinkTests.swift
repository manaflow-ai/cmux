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

    func make() -> (HomeCloudLink, CloudHomeSource, FakeTokens) {
        let tokens = FakeTokens()
        let lease = HomeCloudLease(tokens: tokens, apiBaseURL: URL(string: "https://cloud-api.test")!, clientVersion: nil,
                                   logger: Logger(subsystem: "cmux-next-tests", category: "lease"))
        let source = CloudHomeSource(me: Participant(id: F.localMe, kind: .human, displayName: "Me"))
        return (HomeCloudLink(lease: lease, source: source, localID: F.localMe), source, tokens)
    }

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
}
