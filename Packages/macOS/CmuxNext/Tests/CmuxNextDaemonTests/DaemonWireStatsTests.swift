import Darwin
import Foundation
import Testing
@testable import CmuxNextDaemon

/// `DaemonWireStats`: the app side of the daemon wire, counted lock-free (p05-ipc-004). The fake
/// daemon tests are the red baselines of later tasks: 095 (one connection per app) turns
/// `connectionsOpenedTotal == 3` into 1, 090 (one parse per message) turns `decodesPerLine` toward
/// 1, and 113 (terminal output in a shared ring) turns `outputBytesCopiedApp > 0` into 0.
@Suite(.timeLimit(.minutes(1)))
struct DaemonWireStatsTests {
    static let mebibyte = 1 << 20

    /// The production openers, with the recorder on the endpoint: the app's control connection
    /// (`DaemonConnection`, role main) and two terminal views, each on a connection of its own
    /// (today's per-view path).
    @Test func twoTerminalsOnAFakeDaemonOpenThreeConnectionsAndCopyTheirOutput() async throws {
        let stats = DaemonWireStats()
        let daemon = try FakeWireDaemon(outputBytesPerAttach: Self.mebibyte)
        defer { daemon.stop() }
        let endpoint = DaemonEndpoint(socketPath: daemon.path, wireStats: stats)

        let control = DaemonConnection(endpoint: endpoint, configuration: Self.configuration(role: .main))
        _ = try await control.start()
        var attachments: [TerminalAttachment] = []
        for surface: UInt64 in [1, 2] {
            attachments.append(try await TerminalAttachment.attach(
                endpoint: endpoint, target: .init(surface: SurfaceID(rawValue: surface)),
                size: CellSize(cols: 80, rows: 24), claimGeometry: false))
        }
        for attachment in attachments {
            #expect(await Self.outputBytes(of: attachment, atLeast: Self.mebibyte) >= Self.mebibyte)
        }

        let snapshot = stats.snapshot()
        #expect(snapshot.connectionsOpenedTotal == 3)
        #expect(snapshot.connectionsOpened[.control] == 1)
        #expect(snapshot.connectionsOpened[.terminalAttach] == 2)
        #expect(snapshot.bridgeSpawnsTotal == 0)
        // Per terminal: the splitter copies each output line in and out (each line at least the
        // base64 of its chunk), the decode copies the payload out of the line, and merges copy again.
        let base64Bytes = FakeWireDaemon.chunks(for: Self.mebibyte) * FakeWireDaemon.base64Bytes(of: FakeWireDaemon.chunkBytes)
        #expect(snapshot.outputBytesCopiedApp >= UInt64(2 * (2 * base64Bytes + Self.mebibyte)))
        #expect(snapshot.framesRead[.event] == UInt64(2 * FakeWireDaemon.chunks(for: Self.mebibyte)))
        // The daemon sends one line that is not JSON before each identify reply.
        #expect(snapshot.framesRead[.ignored] == 3)
        #expect(snapshot.framesRead[.droppedReply] == 0)
        #expect(snapshot.framesRead.values.reduce(0, +) == snapshot.linesRead)
        #expect(snapshot.linesWritten == snapshot.framesRead[.reply])
        #expect(snapshot.bytesRead >= UInt64(2 * base64Bytes))
        #expect(snapshot.bytesWritten > 0)

        for attachment in attachments { attachment.detachNow() }
        await control.close()
    }

    /// A page relay's `DaemonConnection` opens its connection with role page_relay.
    @Test func aPageRelayConnectionCountsAsPageRelay() async throws {
        let stats = DaemonWireStats()
        let daemon = try FakeWireDaemon(outputBytesPerAttach: 0)
        defer { daemon.stop() }
        let relay = DaemonConnection(endpoint: DaemonEndpoint(socketPath: daemon.path, wireStats: stats),
                                     configuration: Self.configuration(role: .pageRelay))
        _ = try await relay.start()
        let snapshot = stats.snapshot()
        #expect(snapshot.connectionsOpened[.pageRelay] == 1)
        #expect(snapshot.connectionsOpenedTotal == 1)
        await relay.close()
    }

    /// Decodes are counted where they happen, one per parse. On one attach connection:
    /// - a line that is not JSON: the envelope's try (1),
    /// - `identify`: envelope and reply (2),
    /// - `set-client-info`: envelope only; the attach never reads its data (1),
    /// - `attach-surface`: envelope and reply (2),
    /// - `colors-changed`: envelope, surface scope and colors (3),
    /// - one `output`: envelope and payload (2).
    @Test func anAttachCountsEachDecodeWhereItHappens() async throws {
        let stats = DaemonWireStats()
        let daemon = try FakeWireDaemon(outputBytesPerAttach: 1000, colorsBeforeOutput: true)
        defer { daemon.stop() }
        let attachment = try await TerminalAttachment.attach(
            endpoint: DaemonEndpoint(socketPath: daemon.path, wireStats: stats), target: .init(surface: SurfaceID(rawValue: 1)),
            size: CellSize(cols: 80, rows: 24), claimGeometry: false)
        var sawColors = false
        for await event in attachment.events {
            if case .colorsChanged = event { sawColors = true }
            if case .output = event { break }
        }
        #expect(sawColors)

        let snapshot = stats.snapshot()
        #expect(snapshot.linesRead == 6)
        #expect(snapshot.framesRead[.ignored] == 1)
        #expect(snapshot.framesRead[.reply] == 3)
        #expect(snapshot.framesRead[.event] == 2)
        #expect(snapshot.jsonDecodes == 11)
        // The splitter copies every byte in and every line out (lines without their newline), the
        // decode copies the 1000 payload bytes out; one chunk is never merged.
        #expect(snapshot.outputBytesCopiedApp == snapshot.bytesRead + (snapshot.bytesRead - snapshot.linesRead) + 1000)
        attachment.detachNow()
    }

    /// A reply with no request waiting, or to a request sent without waiting, is dropped and
    /// counted as such, never as a read reply.
    @Test func repliesNobodyReadsCountAsDropped() async throws {
        let stats = DaemonWireStats()
        let daemon = try FakeWireDaemon(outputBytesPerAttach: 0)
        defer { daemon.stop() }
        let transport = try LineTransport(path: daemon.path, role: .control, stats: stats)
        transport.start(onEvent: { _, _, _ in }, onClose: { _ in })
        defer { transport.close() }
        try transport.sendNoReply(cmd: IdentifyRequest.command) { id in try WireCoding.encodeRequest(IdentifyRequest(), id: id) }
        // Ordered after the discarded reply on the same connection: when it returns, that reply was routed.
        _ = try await DaemonConnection.perform(IdentifyRequest(), on: transport)
        let snapshot = stats.snapshot()
        #expect(snapshot.framesRead[.droppedReply] == 1)
        #expect(snapshot.framesRead[.reply] == 1)
    }

    @Test func mergingQueuedOutputCountsACopy() async {
        let stats = DaemonWireStats()
        let queue = TerminalEventQueue(recorder: stats.recorder())
        queue.push(.output(Data(repeating: 0x61, count: 10), colors: nil))
        queue.push(.output(Data(repeating: 0x62, count: 10), colors: nil))
        #expect(stats.snapshot().outputBytesCopiedApp == 0)
        guard case .output(let merged, nil)? = await queue.next() else {
            Issue.record("expected one merged output chunk")
            return
        }
        #expect(merged.count == 20)
        #expect(stats.snapshot().outputBytesCopiedApp == 20)
    }

    @Test func aSingleQueuedChunkIsNotCopied() async {
        let stats = DaemonWireStats()
        let queue = TerminalEventQueue(recorder: stats.recorder())
        queue.push(.output(Data(repeating: 0x61, count: 10), colors: nil))
        _ = await queue.next()
        #expect(stats.snapshot().outputBytesCopiedApp == 0)
    }

    /// Transports take the stripes in turn, and a snapshot sums every stripe, also while many
    /// threads record at once.
    @Test func concurrentCountsOnEveryStripeAddUp() {
        let stats = DaemonWireStats()
        let recorders = (0..<(2 * DaemonWireStats.stripeCount)).map { _ in stats.recorder() }
        #expect(Set(recorders.map(\.stripe)).count == DaemonWireStats.stripeCount)
        let perRecorder = 10_000
        DispatchQueue.concurrentPerform(iterations: recorders.count) { index in
            let recorder = recorders[index]
            for _ in 0..<perRecorder {
                recorder.lineRead(.event)
                recorder.decoded()
                recorder.bytesRead(3)
            }
        }
        let snapshot = stats.snapshot()
        let total = UInt64(recorders.count * perRecorder)
        #expect(snapshot.linesRead == total)
        #expect(snapshot.framesRead[.event] == total)
        #expect(snapshot.jsonDecodes == total)
        #expect(snapshot.bytesRead == 3 * total)
        #expect(snapshot.decodesPerLine == 1)
    }

    @Test func resetZeroesTrafficButKeepsConnections() {
        let stats = DaemonWireStats()
        let attach = stats.recorder(), control = stats.recorder()
        attach.connectionOpened(.terminalAttach, bridged: true)
        control.connectionOpened(.control, bridged: false)
        attach.connectionClosed(.terminalAttach)
        control.lineWritten(bytes: 12)
        attach.outputCopied(5)
        stats.resetTraffic()
        let snapshot = stats.snapshot()
        #expect(snapshot.linesWritten == 0)
        #expect(snapshot.bytesWritten == 0)
        #expect(snapshot.outputBytesCopiedApp == 0)
        #expect(snapshot.connectionsOpenedTotal == 2)
        #expect(snapshot.bridgeSpawns[.terminalAttach] == 1)
        #expect(snapshot.bridgeSpawnsTotal == 1)
        #expect(snapshot.connectionsOpen[.terminalAttach] == 0)
        #expect(snapshot.connectionsOpen[.control] == 1)
    }

    /// No recorder: a transport records nothing (a release build), and the decoder is plain.
    @Test func aTransportWithoutStatsRecordsNothing() async throws {
        let daemon = try FakeWireDaemon(outputBytesPerAttach: 0)
        defer { daemon.stop() }
        let transport = try LineTransport(path: daemon.path, role: .control, stats: nil)
        transport.start(onEvent: { _, _, _ in }, onClose: { _ in })
        defer { transport.close() }
        #expect(transport.recorder == nil)
        #expect(try await DaemonConnection.perform(IdentifyRequest(), on: transport).app == "cmux-tui")
    }

    static func configuration(role: DaemonClientRole) -> DaemonConnection.Configuration {
        var configuration = DaemonConnection.Configuration(requiredCapabilities: [], terminalEnvironment: nil, role: role,
                                                           relayIdentity: role == .pageRelay ? PageRelayIdentity() : nil)
        configuration.heartbeat = .seconds(300)
        return configuration
    }

    /// Output bytes the view reads from `attachment` until it has `atLeast` of them.
    private static func outputBytes(of attachment: TerminalAttachment, atLeast: Int) async -> Int {
        var total = 0
        for await event in attachment.events {
            if case .output(let data, _) = event { total += data.count }
            if total >= atLeast { break }
        }
        return total
    }
}

/// A Unix socket served by this test process that speaks just enough raw protocol v12 for control,
/// page relay and byte-mode terminal attach connections: `identify` (after one line that is not
/// JSON; it offers `origin-claim-v1`), `client-hello` with a connection id, `ok:true` for every
/// other request, and after each `attach-surface` reply an optional `colors-changed`, then
/// `outputBytesPerAttach` bytes of `output` events in 64 KiB chunks.
private final class FakeWireDaemon: Sendable {
    static let chunkBytes = 64 << 10

    let path: String
    private let listener: Int32

    static func chunks(for bytes: Int) -> Int { (bytes + chunkBytes - 1) / chunkBytes }
    static func base64Bytes(of bytes: Int) -> Int { (bytes + 2) / 3 * 4 }

    init(outputBytesPerAttach: Int, colorsBeforeOutput: Bool = false) throws {
        path = "/tmp/cnd-wire-\(UUID().uuidString.prefix(8).lowercased()).sock"
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 8) == 0 else {
            close(listener)
            throw POSIXError(.EADDRINUSE)
        }
        let listener = listener
        let script = Script(outputBytes: outputBytesPerAttach, colors: colorsBeforeOutput)
        let thread = Thread {
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                let serving = Thread { Self.serve(client, script: script) }
                serving.qualityOfService = .utility
                serving.start()
            }
        }
        thread.qualityOfService = .utility
        thread.start()
    }

    func stop() {
        shutdown(listener, SHUT_RDWR)
        close(listener)
        unlink(path)
    }

    /// What every connection is sent after its `attach-surface` reply.
    private struct Script: Sendable {
        var outputBytes: Int
        var colors: Bool
    }

    private static func serve(_ client: Int32, script: Script) {
        defer { close(client) }
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = recv(client, &chunk, chunk.count, 0)
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = request["id"] as? Int, let command = request["cmd"] as? String else { continue }
                guard answer(command, id: id, request: request, to: client, script: script) else { return }
            }
        }
    }

    private static func answer(_ command: String, id: Int, request: [String: Any], to client: Int32, script: Script) -> Bool {
        switch command {
        case IdentifyRequest.command:
            let identity: [String: Any] = ["app": "cmux-tui", "protocol": 12, "generation": "gen-wire",
                                           "capabilities": [DaemonClientRole.originClaimCapability]]
            return write(Data("{]".utf8), to: client) && reply(id, data: identity, to: client)
        case "client-hello":
            return reply(id, data: ["connection_id": "conn-\(id)"], to: client)
        case AttachSurfaceRequest.command:
            guard reply(id, data: ["lease": "lease-\(id)"], to: client) else { return false }
            let surface = request["surface"] as? Int ?? 0
            if script.colors, !send(["event": "colors-changed", "surface": surface, "fg": "#ffffff"], to: client) { return false }
            var sent = 0
            while sent < script.outputBytes {
                let size = min(chunkBytes, script.outputBytes - sent)
                let event: [String: Any] = ["event": "output", "surface": surface,
                                            "data": Data(repeating: 0x61, count: size).base64EncodedString()]
                guard send(event, to: client) else { return false }
                sent += size
            }
            return true
        default:
            return reply(id, data: [String: Any](), to: client)
        }
    }

    private static func reply(_ id: Int, data: [String: Any], to client: Int32) -> Bool {
        send(["id": id, "ok": true, "data": data], to: client)
    }

    private static func send(_ object: [String: Any], to client: Int32) -> Bool {
        guard let line = try? JSONSerialization.data(withJSONObject: object) else { return false }
        return write(line, to: client)
    }

    /// Writes `line` and its newline whole.
    private static func write(_ line: Data, to client: Int32) -> Bool {
        var bytes = line
        bytes.append(0x0A)
        return bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.send(client, base + offset, raw.count - offset, 0)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}
