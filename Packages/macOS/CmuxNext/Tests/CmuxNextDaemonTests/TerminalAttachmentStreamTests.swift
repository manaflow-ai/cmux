import Foundation
import Testing
@testable import CmuxNextDaemon

/// Terminal views as client-minted streams on the app's control connection (attach-streams-v1):
/// a view opens no connection and sends no handshake of its own, its commands name its stream, detaching
/// cancels the stream, and its `stream-end` frees the id. DaemonWireStatsTests'
/// `twoTerminalsOnAFakeDaemonOpenThreeConnectionsAndCopyTheirOutput` is the per-view baseline (3 connections).
@Suite(.timeLimit(.minutes(1)))
struct TerminalAttachmentStreamTests {
    private static let size = CellSize(cols: 80, rows: 24)

    private static func configuration(streams: Bool = true) -> DaemonConnection.Configuration {
        var configuration = DaemonWireStatsTests.configuration(role: .main)
        configuration.terminalStreams = streams
        return configuration
    }

    private static func connect(_ daemon: StreamWireDaemon, stats: DaemonWireStats? = nil,
                                streams: Bool = true) async throws -> DaemonConnection {
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: daemon.path, wireStats: stats),
                                          configuration: configuration(streams: streams))
        _ = try await connection.start()
        return connection
    }

    private static func attach(_ surface: UInt64, on connection: DaemonConnection) async throws -> TerminalAttachment {
        try await TerminalAttachment.attach(on: connection, target: .init(surface: SurfaceID(rawValue: surface)),
                                            size: size, claimGeometry: false)
    }

    /// Requests after the control connection's handshake: one round trip on the same connection orders them.
    private static func requestsAfterHandshake(_ daemon: StreamWireDaemon, _ connection: DaemonConnection) async throws
        -> [StreamWireDaemon.Request] {
        _ = try await connection.request(IdentifyRequest(), timeout: .seconds(5))
        let all = daemon.requests
        let handshake = try #require(all.firstIndex { $0.cmd == SubscribeRequest.command })
        return Array(all[(handshake + 1)...].dropLast())
    }

    /// The view's events until its first output, and that output's bytes.
    private static func firstOutput(of attachment: TerminalAttachment) async -> Data? {
        for await event in attachment.events {
            if case .output(let data, _) = event { return data }
        }
        return nil
    }

    private static func closeReason(of attachment: TerminalAttachment) async -> TerminalChannelCloseReason? {
        for await event in attachment.events {
            if case .closed(let reason) = event { return reason }
        }
        return nil
    }

    /// Red on the per-view path (3 connections, an identify and a set-client-info per view): two views of
    /// two terminals open no connection, send exactly one request each, and get their own output.
    @Test func twoViewsRideTheControlConnectionWithNoHandshake() async throws {
        let stats = DaemonWireStats()
        let daemon = try StreamWireDaemon(.init(outputBytes: [1: 1000, 2: 2000]))
        defer { daemon.stop() }
        let connection = try await Self.connect(daemon, stats: stats)
        let first = try await Self.attach(1, on: connection)
        let second = try await Self.attach(2, on: connection)

        #expect(await Self.firstOutput(of: first)?.allSatisfy { $0 == UInt8(ascii: "b") } == true)
        #expect(await Self.firstOutput(of: second)?.allSatisfy { $0 == UInt8(ascii: "c") } == true)
        let snapshot = stats.snapshot()
        #expect(snapshot.connectionsOpenedTotal == 1)
        #expect(snapshot.connectionsOpened[.terminalAttach, default: 0] == 0)
        #expect(snapshot.bridgeSpawnsTotal == 0)
        #expect(daemon.connections == 1)
        let views = try await Self.requestsAfterHandshake(daemon, connection)
        #expect(views.map(\.cmd) == [AttachSurfaceRequest.command, AttachSurfaceRequest.command])
        #expect(views.map(\.stream) == [1, 2])
        first.detachNow()
        second.detachNow()
        await connection.close()
    }

    /// A view's commands carry its stream, so the daemon checks them against its view.
    @Test func aViewsCommandsNameItsStream() async throws {
        let daemon = try StreamWireDaemon()
        defer { daemon.stop() }
        let connection = try await Self.connect(daemon)
        let view = try await Self.attach(4, on: connection)
        view.sendResize(CellSize(cols: 100, rows: 30))
        view.requestSnapshot(reason: .gap)
        view.sendReleaseGeometry()
        let sent = try await Self.requestsAfterHandshake(daemon, connection).dropFirst()
        #expect(sent.map(\.cmd) == [ResizeAttachedViewRequest.command, SnapshotRequestRequest.command,
                                    ReleaseAttachedViewSizeRequest.command])
        #expect(sent.allSatisfy { $0.stream == 1 })
        view.detachNow()
        await connection.close()
    }

    /// Detaching sends `cancel-stream` (no `detach-attached-view`), ends the view's channel, and the
    /// `stream-end` frees the id, so the next view takes it again only after every other id.
    @Test func detachingCancelsTheStreamAndItsEndFreesTheID() async throws {
        let daemon = try StreamWireDaemon()
        defer { daemon.stop() }
        let connection = try await Self.connect(daemon)
        let view = try await Self.attach(1, on: connection)
        #expect(view.stream?.id == 1)
        let transport = view.transport
        #expect(transport.attachStreamCount == 1)
        view.detachNow()
        view.detachNow()
        #expect(await Self.closeReason(of: view) == .detachedByClient)
        let sent = try await Self.requestsAfterHandshake(daemon, connection).dropFirst()
        #expect(sent.map(\.cmd) == [CancelStreamRequest.command])
        #expect(sent.first?.stream == 1)
        #expect(transport.attachStreamCount == 0)
        let next = try await Self.attach(2, on: connection)
        #expect(next.stream?.id == 2)
        next.detachNow()
        await connection.close()
    }

    /// A failed attach frees its id whether or not the daemon took it: its `stream-end {attach_failed}`
    /// comes before the error reply, and an error with no `stream-end` means it never took the id.
    @Test(arguments: [StreamWireDaemon.Failure.afterClaim, .beforeClaim])
    func aFailedAttachFreesItsID(failure: StreamWireDaemon.Failure) async throws {
        let daemon = try StreamWireDaemon(.init(failures: [9: failure]))
        defer { daemon.stop() }
        let connection = try await Self.connect(daemon)
        let survivor = try await Self.attach(1, on: connection)
        await #expect(throws: DaemonError.self) { _ = try await Self.attach(9, on: connection) }
        #expect(survivor.transport.attachStreamCount == 1)
        survivor.detachNow()
        await connection.close()
    }

    /// A view that stops reading never blocks the shared reader: it loses its stream at the queue's high water
    /// (the daemon is told with `cancel-stream`) while the other view and the control replies keep flowing.
    @Test func aStoppedViewLosesOnlyItsOwnStream() async throws {
        let daemon = try StreamWireDaemon(.init(outputBytes: [1: 9 << 20, 2: 1000]))
        defer { daemon.stop() }
        let connection = try await Self.connect(daemon)
        let stopped = try await Self.attach(1, on: connection)
        let reading = try await Self.attach(2, on: connection)
        #expect(await Self.firstOutput(of: reading) != nil)
        let sent = try await Self.requestsAfterHandshake(daemon, connection)
        #expect(sent.contains(StreamWireDaemon.Request(connection: 1, cmd: CancelStreamRequest.command, stream: 1)))
        #expect(await Self.closeReason(of: stopped) == .overflow)
        reading.detachNow()
        await connection.close()
    }

    /// Losing the connection ends every stream; the views reattach on the next one.
    @Test func connectionLossEndsEveryStream() async throws {
        let daemon = try StreamWireDaemon()
        let connection = try await Self.connect(daemon)
        let views = [try await Self.attach(1, on: connection), try await Self.attach(2, on: connection)]
        await connection.close()
        daemon.stop()
        for view in views {
            guard case .connectionLost? = await Self.closeReason(of: view) else {
                Issue.record("a view on a closed connection must end with connectionLost")
                continue
            }
        }
    }

    /// Red before the fix (a view that reattached while the connection reconnected opened a connection of its
    /// own to the endpoint of the lost epoch): the view waits for the connection's next epoch and streams on it.
    @Test func aViewThatReattachesWhileTheConnectionReconnectsStreamsOnTheNextEpoch() async throws {
        let stats = DaemonWireStats()
        let daemon = try StreamWireDaemon(.init(outputBytes: [1: 10, 2: 10]))
        defer { daemon.stop() }
        let connection = try await Self.connect(daemon, stats: stats)
        let lost = try await Self.attach(1, on: connection)
        daemon.dropConnections()
        guard case .connectionLost? = await Self.closeReason(of: lost) else {
            Issue.record("a view whose connection dropped must end with connectionLost")
            return
        }
        let again = try await Self.attach(2, on: connection)
        #expect(again.stream != nil)
        #expect(await Self.firstOutput(of: again)?.allSatisfy { $0 == UInt8(ascii: "c") } == true)
        #expect(stats.snapshot().connectionsOpened[.terminalAttach, default: 0] == 0)
        #expect(daemon.connections == 2, "the first epoch and the reconnect, no connection of the view's own")
        again.detachNow()
        await connection.close()
    }

    /// A view attached before the connection's first connect waits for it instead of failing `notConnected`.
    @Test func aViewAttachedBeforeTheFirstConnectWaitsForIt() async throws {
        let stats = DaemonWireStats()
        let daemon = try StreamWireDaemon(.init(outputBytes: [1: 10]))
        defer { daemon.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: daemon.path, wireStats: stats),
                                          configuration: Self.configuration())
        let early = Task { try await Self.attach(1, on: connection) }
        _ = try await connection.start()
        let view = try await early.value
        #expect(view.stream != nil)
        #expect(await Self.firstOutput(of: view) != nil)
        #expect(stats.snapshot().connectionsOpened[.terminalAttach, default: 0] == 0)
        view.detachNow()
        await connection.close()
    }

    /// Red before the fix (the history counted toward the stream's overflow bound, so the view lost its stream
    /// before it could read, and every reattach got the same burst): the history and images the daemon sends
    /// after a READY never end the stream, however far past the high water they reach before the view reads.
    @Test func aHistoryBurstPastTheHighWaterNeverOverflowsTheStream() async throws {
        let history = 12 << 20
        let daemon = try StreamWireDaemon(.init(outputBytes: [1: 1000], historyBytes: [1: history]))
        defer { daemon.stop() }
        let connection = try await Self.connect(daemon)
        let view = try await Self.attach(1, on: connection)
        // One round trip behind the burst: every history chunk is in the view's queue before it reads one.
        _ = try await connection.request(IdentifyRequest(), timeout: .seconds(5))
        var sawReady = false
        var historyRead = 0
        var closed: TerminalChannelCloseReason?
        reading: for await event in view.events {
            switch event {
            case .snapshot(let frame) where frame.phase == .ready: sawReady = true
            case .snapshot(let frame) where frame.phase == .history: historyRead += frame.data.count
            case .output: break reading
            case .closed(let reason):
                closed = reason
                break reading
            default: break
            }
        }
        #expect(closed == nil)
        #expect(sawReady)
        #expect(historyRead == history)
        #expect(!daemon.requests.contains { $0.cmd == CancelStreamRequest.command })
        view.detachNow()
        await connection.close()
    }

    /// Red before the fix (the `cancel-stream` reply was dropped, so the id stayed taken until the connection
    /// closed): an attach that timed out and that the daemon refused before it took the id frees the id at the
    /// `ended` reply of its `cancel-stream`.
    @Test func anAttachThatTimedOutAndWasNeverOpenedFreesItsID() async throws {
        let daemon = try StreamWireDaemon(.init(failures: [9: .beforeClaimAfterTheDeadline]))
        defer { daemon.stop() }
        let connection = try await Self.connect(daemon)
        guard case .stream(let carrier) = try await TerminalStreamCarrier.route(for: connection) else {
            Issue.record("a streaming connection to a daemon that offers the grant carries streams")
            return
        }
        await #expect(throws: DaemonError.self) {
            _ = try await TerminalAttachment.attachStream(
                on: carrier, target: .init(surface: SurfaceID(rawValue: 9)), size: Self.size, claimGeometry: false,
                snapshotVersion: nil, localHistory: false, images: false, createIntent: 0, timeout: .milliseconds(50))
        }
        // The cancel-stream went out at the timeout; its reply rides ahead of this round trip's.
        _ = try await connection.request(IdentifyRequest(), timeout: .seconds(5))
        #expect(carrier.transport.attachStreamCount == 0)
        #expect(daemon.requests.filter { $0.cmd == CancelStreamRequest.command }.map(\.stream) == [1])
        await connection.close()
    }

    /// The flag off, or a daemon that does not offer the grant, keeps each view on a connection of its own.
    @Test(arguments: [(false, true), (true, false)])
    func withoutTheGrantAViewOpensItsOwnConnection(streams: Bool, offered: Bool) async throws {
        let stats = DaemonWireStats()
        let daemon = try StreamWireDaemon(.init(offersStreams: offered, outputBytes: [1: 10]))
        defer { daemon.stop() }
        let connection = try await Self.connect(daemon, stats: stats, streams: streams)
        let view = try await Self.attach(1, on: connection)
        #expect(view.stream == nil)
        #expect(await Self.firstOutput(of: view) != nil)
        #expect(stats.snapshot().connectionsOpened[.terminalAttach, default: 0] == 1)
        #expect(daemon.requests.filter { $0.cmd == AttachSurfaceRequest.command }.allSatisfy { $0.stream == nil })
        view.detachNow()
        await connection.close()
    }
}


/// The client-minted id table of one connection (``AttachStreamTable``).
struct AttachStreamTableTests {
    /// A sink that reads nothing.
    private static let sink = AttachStreamSink(dispatch: .control) { _ in }

    private static func delivers(_ route: AttachStreamTable.Route) -> Bool {
        if case .deliver = route { true } else { false }
    }

    private static func drops(_ route: AttachStreamTable.Route) -> Bool {
        if case .dropped = route { true } else { false }
    }

    /// Reserves outside `#require`: the macro wraps its argument in a closure, which cannot call a mutating method.
    private static func reserve(_ table: inout AttachStreamTable) throws -> AttachStreamHandle {
        let handle = table.reserve()
        return try #require(handle)
    }

    @Test func idsSkipTakenOnesAndWrapPastZero() throws {
        var table = AttachStreamTable()
        let first = try Self.reserve(&table)
        let second = try Self.reserve(&table)
        #expect([first.id, second.id] == [1, 2])
        let cancelled = table.cancel(first)
        #expect(cancelled)
        // Cancelled, not ended: the id stays taken until its stream-end.
        _ = table.route(first.id, ended: true)
        var last = second
        for _ in 3...Int(UInt16.max) { last = try Self.reserve(&table) }
        #expect(last.id == UInt16.max)
        let wrapped = try Self.reserve(&table)
        #expect(wrapped.id == 1, "0 is the control sequence; 2 is still taken")
        let full = table.reserve()
        #expect(full == nil, "every id is taken")
    }

    @Test func aStaleHandleNeverTouchesANewerStreamOfItsID() throws {
        var table = AttachStreamTable()
        let old = try Self.reserve(&table)
        let boundOld = table.bind(old, Self.sink)
        #expect(boundOld)
        let ended = table.route(old.id, ended: true)
        #expect(Self.delivers(ended), "the open stream gets its end")
        for _ in 2...Int(UInt16.max) { _ = table.reserve() }
        let newer = try Self.reserve(&table)
        #expect(newer.id == old.id)
        table.release(old)
        let cancelledOld = table.cancel(old)
        #expect(!cancelledOld)
        let boundNewer = table.bind(newer, Self.sink)
        #expect(boundNewer)
        let routed = table.route(newer.id, ended: false)
        #expect(Self.delivers(routed), "the newer stream still routes")
    }

    @Test func itemsOfAReservedOrCancelledStreamAreDropped() throws {
        var table = AttachStreamTable()
        let beforeAny = table.route(9, ended: false)
        if case .unknown = beforeAny {} else { Issue.record("a connection that never minted routes it as control") }
        let handle = try Self.reserve(&table)
        let reserved = table.route(handle.id, ended: false)
        #expect(Self.drops(reserved))
        let stale = table.route(9, ended: false)
        #expect(Self.drops(stale), "once streams are minted, an id not held is no control line")
        let bound = table.bind(handle, Self.sink)
        let cancelled = table.cancel(handle)
        #expect(bound && cancelled)
        let afterCancel = table.route(handle.id, ended: false)
        #expect(Self.drops(afterCancel))
        #expect(table.count == 1)
        let end = table.route(handle.id, ended: true)
        #expect(Self.drops(end))
        #expect(table.count == 0, "its end frees it")
    }

    @Test func connectionLossTellsEveryOpenStreamAndMintsNoMore() throws {
        var table = AttachStreamTable()
        let open = try Self.reserve(&table)
        let bound = table.bind(open, Self.sink)
        #expect(bound)
        _ = table.reserve()
        let told = table.endAll()
        #expect(told.count == 1)
        #expect(table.count == 0)
        let after = table.reserve()
        #expect(after == nil)
    }
}
