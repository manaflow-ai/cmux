import Foundation
import Testing
@testable import CmuxNextDaemon

/// A stream view's priority (`set-stream-priority`) on the attach streams of p05-ipc-095: a view
/// that rides a stream sends each change once, naming its stream; the same priority again, a priority after
/// it detached, and any priority of a view on a connection of its own send nothing. Served by
/// ``StreamWireDaemon``, which records every request in each connection's order.
@Suite(.timeLimit(.minutes(1)))
struct TerminalAttachmentStreamPriorityTests {
    private static func connect(_ daemon: StreamWireDaemon, streams: Bool = true) async throws -> DaemonConnection {
        var configuration = DaemonWireStatsTests.configuration(role: .main)
        configuration.terminalStreams = streams
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: daemon.path), configuration: configuration)
        _ = try await connection.start()
        return connection
    }

    private static func attach(_ surface: UInt64, on connection: DaemonConnection) async throws -> TerminalAttachment {
        try await TerminalAttachment.attach(on: connection, target: .init(surface: SurfaceID(rawValue: surface)),
                                            size: CellSize(cols: 80, rows: 24), claimGeometry: false)
    }

    /// The commands sent on `transport` before now: a round trip on it orders them, as the daemon reads each
    /// connection in turn.
    private static func commands(_ daemon: StreamWireDaemon, on transport: LineTransport) async throws
        -> [StreamWireDaemon.Request] {
        _ = try await DaemonConnection.perform(IdentifyRequest(), on: transport, timeout: .seconds(5))
        return daemon.requests
    }

    private static func priorities(_ requests: [StreamWireDaemon.Request]) -> [StreamWireDaemon.Request] {
        requests.filter { $0.cmd == SetStreamPriorityRequest.command }
    }

    @Test func aStreamViewSendsEachChangeOnceNamingItsStream() async throws {
        let daemon = try StreamWireDaemon()
        defer { daemon.stop() }
        let connection = try await Self.connect(daemon)
        let view = try await Self.attach(1, on: connection)
        #expect(view.stream?.id == 1)
        view.setStreamPriority(.hidden)
        view.setStreamPriority(.hidden)
        view.setStreamPriority(.focused)
        view.setStreamPriority(.focused)
        view.setStreamPriority(.visible)
        let sent = Self.priorities(try await Self.commands(daemon, on: view.transport))
        #expect(sent.count == 3)
        #expect(sent.allSatisfy { $0.stream == 1 })
        view.detachNow()
        await connection.close()
    }

    @Test func aDetachedViewSendsNoPriority() async throws {
        let daemon = try StreamWireDaemon()
        defer { daemon.stop() }
        let connection = try await Self.connect(daemon)
        let view = try await Self.attach(1, on: connection)
        view.detachNow()
        view.setStreamPriority(.hidden)
        let sent = try await Self.commands(daemon, on: view.transport)
        #expect(sent.contains { $0.cmd == CancelStreamRequest.command })
        #expect(Self.priorities(sent).isEmpty)
        await connection.close()
    }

    @Test func aViewOnAConnectionOfItsOwnSendsNoPriority() async throws {
        let daemon = try StreamWireDaemon()
        defer { daemon.stop() }
        let connection = try await Self.connect(daemon, streams: false)
        let view = try await Self.attach(1, on: connection)
        #expect(view.stream == nil)
        view.setStreamPriority(.hidden)
        view.setStreamPriority(.focused)
        #expect(Self.priorities(try await Self.commands(daemon, on: view.transport)).isEmpty)
        view.detachNow()
        await connection.close()
    }

    /// The wire shape `cmux-tui/spec/commands.md` gives: `{cmd, stream, priority}`.
    @Test func theRequestCarriesItsStreamAndPriority() throws {
        let line = try WireCoding.encodeRequest(SetStreamPriorityRequest(stream: 3, priority: .hidden), id: 7)
        let fields = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(fields["cmd"] as? String == "set-stream-priority")
        #expect(fields["stream"] as? Int == 3)
        #expect(fields["priority"] as? String == "hidden")
    }
}
