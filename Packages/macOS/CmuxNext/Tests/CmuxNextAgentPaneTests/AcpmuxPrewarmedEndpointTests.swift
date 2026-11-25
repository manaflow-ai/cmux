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
    /// never takes it and forgets it.
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
}
