import CmuxNextCompat
import CmuxNextMetrics
import CmuxNextTrace
import Darwin
import Foundation
import Testing
@testable import CmuxNextDaemon

/// p09-observability-109 at the connection: the app's main connection to its local daemon counts each end of a
/// ready connection once as `stability.child_exit.daemon` (clean after `daemon-shutdown`, signal at an EOF
/// without it), and nothing for a close the app made itself, a connection that never got ready, or a bridge.
/// Every request on a counted daemon's connections, a terminal view's own included, is its last request.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct DaemonConnectionStabilityTests {
    private static func attached() -> (StabilityCounters, MetricsStore) {
        let runtime = TraceRuntime(role: .app)
        let profile = MetricsProfile(appVersion: "1.2.3", buildNumber: "45", channel: "nightly", osVersion: "26.1.0",
                                     hardwareClass: "Mac16,10", buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 28))
        let store = MetricsStore(role: .app, profile: profile, pid: 4242)
        #expect(store.attach(to: runtime))
        return (StabilityCounters(metrics: Metrics(runtime: runtime)), store)
    }

    /// `stability.child_exit.daemon`'s samples as `[ChildExit value: count]`.
    private static func daemonExits(_ store: MetricsStore) -> [Int: UInt64] {
        let name = HistogramID.stabilityChildExit(.daemon).name
        let histogram = store.delta().histograms.first { $0.name == name }
        return Dictionary(uniqueKeysWithValues: (histogram?.buckets ?? []).map { ($0.index, $0.count) })
    }

    /// The main connection's configuration: the local heartbeat on (``DaemonConnectionConfiguration/countsStability(of:)``).
    private static func mainConfiguration(role: DaemonClientRole = .main) -> DaemonConnectionConfiguration {
        var configuration = DaemonConnectionConfiguration(requiredCapabilities: [], requestTimeout: .seconds(5),
                                                          terminalEnvironment: nil, role: role)
        configuration.localHeartbeat = true
        configuration.retryWake = RetryWake(owner: "DaemonConnectionStabilityTests")
        return configuration
    }

    private static func daemon() throws -> WireDaemon {
        try WireDaemon(DaemonHandshakeTests.daemon(offers: []))
    }

    /// Waits for the connection's first `.disconnected`, which it emits after it counted the end.
    private static func firstDisconnect(_ connection: DaemonConnection) async throws -> String? {
        for try await envelope in connection.events {
            if case .disconnected(let reason) = envelope.event { return reason }
        }
        return nil
    }

    @Test func aReadyLocalConnectionThatTheDaemonEndsCountsOneSignal() async throws {
        let daemon = try Self.daemon()
        defer { daemon.stop() }
        let (stability, store) = Self.attached()
        let connection = DaemonConnection(configuration: Self.mainConfiguration(), stability: stability,
                                          endpointProvider: { DaemonEndpoint(socketPath: daemon.path) })
        try await connection.start()
        #expect(Self.daemonExits(store).isEmpty)
        daemon.dropConnections()
        #expect(try await Self.firstDisconnect(connection) == "EOF")
        await connection.close()
        #expect(Self.daemonExits(store) == [Int(HistogramID.ChildExit.signal.rawValue): 1])
    }

    @Test func aDaemonShutdownFirstCountsOneCleanExit() async throws {
        let daemon = try Self.daemon()
        defer { daemon.stop() }
        let (stability, store) = Self.attached()
        let connection = DaemonConnection(configuration: Self.mainConfiguration(), stability: stability,
                                          endpointProvider: { DaemonEndpoint(socketPath: daemon.path) })
        try await connection.start()
        daemon.sendToConnections(Array(#"{"event":"daemon-shutdown"}"#.utf8) + [0x0A])
        daemon.dropConnections()
        _ = try await Self.firstDisconnect(connection)
        await connection.close()
        #expect(Self.daemonExits(store) == [Int(HistogramID.ChildExit.clean.rawValue): 1])
    }

    /// The review's finding: a line the app cannot decode closes the connection on the app's side; the daemon
    /// still runs, so no daemon end is counted.
    @Test func aBadMessageCloseCountsNoDaemonEnd() async throws {
        let daemon = try Self.daemon()
        defer { daemon.stop() }
        let (stability, store) = Self.attached()
        let connection = DaemonConnection(configuration: Self.mainConfiguration(), stability: stability,
                                          endpointProvider: { DaemonEndpoint(socketPath: daemon.path) })
        try await connection.start()
        // {"event":"\xc3\x28"}: not UTF-8 (LineTransportTests' bad line).
        daemon.sendToConnections(Array(#"{"event":""#.utf8) + [0xC3, 0x28] + Array(#""}"#.utf8) + [0x0A])
        #expect(try await Self.firstDisconnect(connection) == "bad message: invalid_utf8")
        await connection.close()
        #expect(Self.daemonExits(store).isEmpty, "the app's own close was counted as the daemon's death")
    }

    /// The app's own close of a ready connection is no daemon end.
    @Test func theAppsCloseCountsNothing() async throws {
        let daemon = try Self.daemon()
        defer { daemon.stop() }
        let (stability, store) = Self.attached()
        let connection = DaemonConnection(configuration: Self.mainConfiguration(), stability: stability,
                                          endpointProvider: { DaemonEndpoint(socketPath: daemon.path) })
        try await connection.start()
        await connection.close()
        #expect(Self.daemonExits(store).isEmpty)
    }

    /// A connection that the daemon ends before it is ready (during the handshake) is no daemon end of a session.
    @Test func aConnectingCloseCountsNothing() async throws {
        var listener: ReplyEventOrderTests.FakeDaemon? = try ReplyEventOrderTests.FakeDaemon()
        let path = try #require(listener?.path)
        let (stability, store) = Self.attached()
        let connection = DaemonConnection(configuration: Self.mainConfiguration(), stability: stability,
                                          endpointProvider: { DaemonEndpoint(socketPath: path) })
        let started = Task { try await connection.start() }
        try listener?.accept()
        listener = nil  // closes the accepted connection before any reply: EOF while connecting
        _ = await started.result
        await connection.close()
        #expect(Self.daemonExits(store).isEmpty)
    }

    /// Only the main connection to a local daemon counts: a page relay shares that daemon, and a bridge's server is
    /// another machine's.
    @Test func onlyTheMainLocalConnectionCounts() {
        let local = DaemonEndpoint(socketPath: "/tmp/cnd-stability.sock")
        let bridged = DaemonEndpoint(socketPath: "/tmp/cnd-stability.sock",
                                     bridge: DaemonBridge(executable: "/usr/bin/true", arguments: []))
        #expect(Self.mainConfiguration().countsStability(of: local))
        #expect(!Self.mainConfiguration().countsStability(of: bridged))
        #expect(!Self.mainConfiguration(role: .pageRelay).countsStability(of: local))
        var plain = Self.mainConfiguration()
        plain.localHeartbeat = false
        #expect(!plain.countsStability(of: local), "a short read or a test connection counted")
    }

    /// The finding of the review: a terminal view's own connection to the counted daemon notes its keys, so a stall
    /// while the person types is `terminal_io`.
    @Test func aTerminalConnectionToTheCountedDaemonNotesItsRequests() async throws {
        let daemon = try Self.daemon()
        defer { daemon.stop() }
        let (stability, _) = Self.attached()
        let connection = DaemonConnection(configuration: Self.mainConfiguration(), stability: stability,
                                          endpointProvider: { DaemonEndpoint(socketPath: daemon.path) })
        try await connection.start()
        let reached = await connection.endpoint
        let endpoint = try #require(reached)
        let note = try #require(endpoint.requests)
        #expect(note === connection.heartbeat.requests)
        let terminal = try await LineTransport.open(path: endpoint.socketPath, bridge: nil, role: .terminalAttach, stats: nil,
                                                    requests: endpoint.requests)
        terminal.start(onEvent: { _, _, _ in }, onClose: { _ in })
        try terminal.sendNoReply(cmd: SendInputRequest.command) { id in Data(#"{"id":\#(id),"cmd":"send"}"#.utf8) }
        #expect(connection.heartbeat.lastRequestClass == .terminalIO)
        terminal.close()
        await connection.close()
    }
}
