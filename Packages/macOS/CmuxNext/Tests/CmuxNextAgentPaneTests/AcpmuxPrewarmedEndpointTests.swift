import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A restored chat's page sent its handshake about a second after the launch prewarm had found the
/// daemon, and the host ran the whole lookup again before the chat could open (CMUX-571: the
/// nightly's restart-to-chat round). The first handshake after the launch prewarm now takes the
/// endpoint the prewarm found.
struct AcpmuxPrewarmedEndpointTests {
    private nonisolated final class Lookups: @unchecked Sendable {  // the lock guards `count`
        private let lock = NSLock()
        private var count = 0
        var runs: Int { lock.withLock { count } }
        func run() -> Int { lock.withLock { count += 1; return count } }
    }

    /// The daemon a kept endpoint answers for, as a test sets it (``AcpmuxHost`` `keptDaemon`).
    private nonisolated final class Daemon: @unchecked Sendable {  // the lock guards `pid`
        private let lock = NSLock()
        private var current: Int32?
        var pid: Int32? {
            get { lock.withLock { current } }
            set { lock.withLock { current = newValue } }
        }
    }

    private static func host(_ lookups: Lookups, daemon: Daemon, failing: Int? = nil) -> AcpmuxHost {
        let root = FileManager.default.temporaryDirectory.appending(path: "acpmux-kept-\(UUID().uuidString.prefix(8))")
        let environment = AcpmuxEnvironment(executable: URL(fileURLWithPath: "/App/bin/acpmux"),
                                            home: root.appending(path: "home"),
                                            socketPath: root.appending(path: "acpmux.sock").path,
                                            daemonArguments: [], childEnvironment: [:])
        return AcpmuxHost(daemons: AcpmuxLocalDaemons(), resolve: { environment },
                          lookup: { _, _ in
                              let run = lookups.run()
                              if run == failing { throw AgentPaneHostError.timedOut }
                              return endpoint(run)
                          }, keptDaemon: { _ in daemon.pid })
    }

    private static func host(_ lookups: Lookups) -> AcpmuxHost {
        let root = FileManager.default.temporaryDirectory.appending(path: "acpmux-prewarm-\(UUID().uuidString.prefix(8))")
        let environment = AcpmuxEnvironment(executable: URL(fileURLWithPath: "/App/bin/acpmux"),
                                            home: root.appending(path: "home"),
                                            socketPath: root.appending(path: "acpmux.sock").path,
                                            daemonArguments: [], childEnvironment: [:])
        return AcpmuxHost(daemons: AcpmuxLocalDaemons(), resolve: { environment },
                          lookup: { _, _ in endpoint(lookups.run()) })
    }

    private nonisolated static func endpoint(_ run: Int) -> AcpmuxWebEndpoint {
        AcpmuxWebEndpoint(url: URL(fileURLWithPath: "/ws/\(run)"), token: "token-\(run)")
    }

    private static func token(_ handshake: AgentPaneHandshake) -> String? {
        handshake.connection?.dashboardToken
    }

    @Test func theFirstHandshakeAfterTheLaunchPrewarmTakesItsEndpoint() async throws {
        let lookups = Lookups()
        let host = Self.host(lookups)
        try await host.prewarmForRestoredChats()
        await host.lookupSettled()
        let handshake = try await host.handshake(sessionId: "s1")
        #expect(lookups.runs == 1)
        #expect(Self.token(handshake) == "token-1")
    }

    /// One handshake takes it: the next one looks up again, so a page whose connect failed on a
    /// daemon that exited meanwhile, or the person-proof recovery, gets a full lookup. A reconnect
    /// never takes one of no known daemon, and forgets it.
    @Test func onlyOneHandshakeTakesIt() async throws {
        let lookups = Lookups()
        let host = Self.host(lookups)
        try await host.prewarmForRestoredChats()
        await host.lookupSettled()
        _ = try await host.handshake(sessionId: "s1")
        #expect(lookups.runs == 1)
        let again = try await host.handshake(sessionId: "s1")
        await host.lookupSettled()
        #expect(lookups.runs == 2)
        #expect(Self.token(again) == "token-2")

        try await host.prewarmForRestoredChats()
        await host.lookupSettled()
        _ = try await host.reconnectHandshake(sessionId: "s1")
        await host.lookupSettled()
        _ = try await host.handshake(sessionId: "s1")
        #expect(lookups.runs == 5)
    }

    /// Any other prewarm (a session transfer, the Chief's keeper) keeps nothing.
    @Test func onlyTheLaunchPrewarmKeeps() async throws {
        let lookups = Lookups()
        let host = Self.host(lookups)
        try await host.prewarm()
        await host.lookupSettled()
        _ = try await host.handshake(sessionId: "s1")
        #expect(lookups.runs == 2)
    }

    @Test func aStaleOrDroppedEndpointAnswersNoHandshake() {
        let found = Self.endpoint(1)
        let start = ContinuousClock.now
        var kept = AcpmuxPrewarmedEndpoint()
        kept.keep(found, at: start, unlessDroppedSince: kept.generation)
        #expect(kept.take(at: start + AcpmuxPrewarmedEndpoint.freshFor + .milliseconds(1)) == nil)

        kept.keep(found, at: start, unlessDroppedSince: kept.generation)
        kept.drop()
        #expect(kept.take(at: start) == nil)

        // A prewarm whose lookup settles after a drop (a restart, a handshake that looked up) keeps nothing.
        let before = kept.generation
        kept.drop()
        kept.keep(found, at: start, unlessDroppedSince: before)
        #expect(kept.take(at: start) == nil)

        kept.keep(found, at: start, unlessDroppedSince: kept.generation)
        #expect(kept.take(at: start + .seconds(1)) == found)
    }

    /// Leo, 2026-11-21, on "Waiting for the agent service (1:07)": "why does it take any time at all
    /// to \"connect\"". While the daemon a lookup found and enrolled serves, every later handshake
    /// (a new chat, a tab, a reload) takes its endpoint with no round trip; one lookup that may not
    /// start a daemon runs behind it and keeps what it finds for the next one.
    @Test func whileItsDaemonServesEveryHandshakeTakesTheKeptEndpoint() async throws {
        let lookups = Lookups()
        let daemon = Daemon()
        daemon.pid = 42
        let host = Self.host(lookups, daemon: daemon)
        let first = try await host.handshake(sessionId: nil)
        await host.lookupSettled()
        #expect(lookups.runs == 1)
        #expect(Self.token(first) == "token-1")

        let second = try await host.handshake(sessionId: nil)
        #expect(Self.token(second) == "token-1")
        await host.revalidationSettled()
        await host.lookupSettled()
        #expect(lookups.runs == 2)

        // The background lookup's endpoint answers the next handshake.
        let third = try await host.handshake(sessionId: "s1")
        #expect(Self.token(third) == "token-2")
        await host.revalidationSettled()
        await host.lookupSettled()
        #expect(lookups.runs == 3)
    }

    /// Another daemon on the socket (a restart, an update's swap) or none that took this launch's
    /// key: the handshake and the reconnect look up in full.
    @Test func anotherDaemonLooksUpAgain() async throws {
        let lookups = Lookups()
        let daemon = Daemon()
        daemon.pid = 42
        let host = Self.host(lookups, daemon: daemon)
        _ = try await host.handshake(sessionId: nil)
        await host.lookupSettled()
        daemon.pid = 43
        let other = try await host.handshake(sessionId: nil)
        await host.lookupSettled()
        #expect(lookups.runs == 2)
        #expect(Self.token(other) == "token-2")

        daemon.pid = 44
        let reconnected = try await host.reconnectHandshake(sessionId: "s1")
        await host.lookupSettled()
        #expect(lookups.runs == 3)
        #expect(Self.token(reconnected) == "token-3")
        daemon.pid = nil
        _ = try await host.handshake(sessionId: "s1")
        await host.lookupSettled()
        #expect(lookups.runs == 4)
        _ = try await host.handshake(sessionId: "s1")
        await host.lookupSettled()
        #expect(lookups.runs == 5)
    }

    /// A kept endpoint of a daemon answers while that daemon serves, however long ago it was found;
    /// one of no known daemon (the launch prewarm's) answers once, within ``AcpmuxPrewarmedEndpoint/freshFor``.
    @Test func aDaemonsEndpointStaysAndAnUnknownOneAnswersOnce() {
        let found = Self.endpoint(1)
        let start = ContinuousClock.now
        var kept = AcpmuxPrewarmedEndpoint()
        kept.keep(found, at: start, daemon: 7, unlessDroppedSince: kept.generation)
        let late = start + AcpmuxPrewarmedEndpoint.freshFor + .seconds(600)
        #expect(kept.take(at: late, daemon: 7) == found)
        #expect(kept.take(at: late, daemon: 7) == found)
        // Another daemon: gone for good.
        #expect(kept.take(at: late, daemon: 8) == nil)
        #expect(kept.take(at: late, daemon: 7) == nil)
    }

    /// The link to the daemon dropped and the daemon that serves is the one the kept endpoint came
    /// from: the reconnect redials it with no lookup (63 socket drops in 24 h on Leo's NIGHTLY Mac
    /// each paid `_acpmux/status`, the key's enroll and the peer-checked status again first). One
    /// lookup runs behind it and keeps what it finds for the next reconnect.
    @Test func aReconnectRedialsTheKeptEndpointWithoutALookup() async throws {
        let lookups = Lookups()
        let daemon = Daemon()
        daemon.pid = 42
        let host = Self.host(lookups, daemon: daemon)
        _ = try await host.handshake(sessionId: "s1")
        await host.lookupSettled()
        #expect(lookups.runs == 1)

        // A lookup of its own would have answered token-2.
        let reconnected = try await host.reconnectHandshake(sessionId: "s1")
        #expect(Self.token(reconnected) == "token-1")
        await host.revalidationSettled()
        await host.lookupSettled()
        #expect(lookups.runs == 2)

        // The background lookup confirmed the daemon: the next reconnect redials what it kept.
        let again = try await host.reconnectHandshake(sessionId: "s1")
        #expect(Self.token(again) == "token-2")
        await host.revalidationSettled()
        await host.lookupSettled()
        #expect(lookups.runs == 3)
    }

    /// A redial whose background lookup failed (the daemon went, its port or token changed) is not
    /// dialed again: the next reconnect falls back to the whole lookup.
    @Test func aReconnectAfterAFailedRedialLooksUpInFull() async throws {
        let lookups = Lookups()
        let daemon = Daemon()
        daemon.pid = 42
        let host = Self.host(lookups, daemon: daemon, failing: 2)
        _ = try await host.handshake(sessionId: "s1")
        await host.lookupSettled()

        let redialed = try await host.reconnectHandshake(sessionId: "s1")
        #expect(Self.token(redialed) == "token-1")
        await host.revalidationSettled()
        await host.lookupSettled()
        #expect(lookups.runs == 2)

        let fallback = try await host.reconnectHandshake(sessionId: "s1")
        await host.lookupSettled()
        #expect(lookups.runs == 3)
        #expect(Self.token(fallback) == "token-3")
    }

    /// A redial answers one reconnect until a lookup keeps an endpoint again: a second reconnect
    /// before that (the redial may be the connect that failed) looks up in full. Only the daemon
    /// the endpoint came from is redialed.
    @Test func aRedialAnswersOneReconnectUntilALookupConfirmsIt() {
        let found = Self.endpoint(1)
        let start = ContinuousClock.now
        var kept = AcpmuxPrewarmedEndpoint()
        kept.keep(found, at: start, daemon: 7, unlessDroppedSince: kept.generation)
        #expect(kept.redial(daemon: 8) == nil)
        #expect(kept.redial(daemon: nil) == nil)
        #expect(kept.redial(daemon: 7) == found)
        #expect(kept.redial(daemon: 7) == nil)

        let confirmed = Self.endpoint(2)
        kept.keep(confirmed, at: start, daemon: 7, unlessDroppedSince: kept.generation)
        #expect(kept.redial(daemon: 7) == confirmed)

        // One of no known daemon (the launch prewarm's) is never redialed.
        kept.drop()
        kept.keep(found, at: start, unlessDroppedSince: kept.generation)
        #expect(kept.redial(daemon: 7) == nil)
        #expect(kept.redial(daemon: nil) == nil)
    }
}
