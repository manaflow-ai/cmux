import Darwin
import Foundation
import Testing
@testable import CmuxNextDaemon

/// `DaemonWireStats`: the app side of the daemon wire, counted lock-free (p05-ipc-004). The fake
/// daemon tests are the red baselines of later tasks: 095 (one connection per app) turns
/// `connectionsOpenedTotal == 3` into 1, and 113 (terminal output in a shared ring) turns
/// `outputBytesCopiedApp > 0` into 0.
@Suite(.timeLimit(.minutes(1)))
struct DaemonWireStatsTests {
    static let mebibyte = 1 << 20

    @Test func twoTerminalsOnAFakeDaemonOpenThreeConnectionsAndCopyTheirOutput() async throws {
        let stats = DaemonWireStats()
        let daemon = try FakeWireDaemon(outputBytesPerAttach: Self.mebibyte)
        defer { daemon.stop() }

        // The app's control connection (DaemonConnection opens it with role main).
        let control = try LineTransport(path: daemon.path, role: .control, stats: stats)
        control.start(onEvent: { _, _, _ in }, onClose: { _ in })
        _ = try await DaemonConnection.perform(IdentifyRequest(), on: control)

        // Two terminal views, each attached on a connection of its own (today's per-view path).
        var attachments: [TerminalAttachment] = []
        for surface: UInt64 in [1, 2] {
            attachments.append(try await TerminalAttachment.attach(
                endpoint: DaemonEndpoint(socketPath: daemon.path),
                target: .init(surface: SurfaceID(rawValue: surface)),
                size: CellSize(cols: 80, rows: 24), claimGeometry: false, wireStats: stats))
        }
        for attachment in attachments {
            #expect(await Self.outputBytes(of: attachment, atLeast: Self.mebibyte) >= Self.mebibyte)
        }

        let snapshot = stats.snapshot()
        #expect(snapshot.connectionsOpenedTotal == 3)
        #expect(snapshot.connectionsOpened[.control] == 1)
        #expect(snapshot.connectionsOpened[.terminalAttach] == 2)
        #expect(snapshot.bridgeSpawnsTotal == 0)
        // Each output byte was decoded out of its JSON line into a buffer of the app's.
        #expect(snapshot.outputBytesCopiedApp >= UInt64(2 * Self.mebibyte))
        // Replies: identify on the control connection; identify, set-client-info and
        // attach-surface on each attach connection. Writes: one line per request.
        #expect(snapshot.framesRead[.reply] == 7)
        #expect(snapshot.linesWritten == 7)
        #expect(snapshot.framesRead[.event] == UInt64(2 * FakeWireDaemon.chunks(for: Self.mebibyte)))
        // The daemon sends one line that is not JSON before each identify reply.
        #expect(snapshot.framesRead[.ignored] == 3)
        #expect(snapshot.framesRead.values.reduce(0, +) == snapshot.linesRead)
        #expect(snapshot.envelopeDecodes == snapshot.linesRead)
        #expect(snapshot.bytesRead >= UInt64(2 * Self.mebibyte))
        #expect(snapshot.bytesWritten > 0)

        for attachment in attachments { attachment.detachNow() }
        control.close()
    }

    @Test func mergingQueuedOutputCountsASecondCopy() async {
        let stats = DaemonWireStats()
        let queue = TerminalEventQueue(stats: stats)
        queue.push(.output(Data(repeating: 0x61, count: 10), colors: nil))
        queue.push(.output(Data(repeating: 0x62, count: 10), colors: nil))
        #expect(stats.snapshot().outputBytesCopiedApp == 20)
        guard case .output(let merged, nil)? = await queue.next() else {
            Issue.record("expected one merged output chunk")
            return
        }
        #expect(merged.count == 20)
        #expect(stats.snapshot().outputBytesCopiedApp == 40)
    }

    @Test func aSingleQueuedChunkIsNotCopiedAgain() async {
        let stats = DaemonWireStats()
        let queue = TerminalEventQueue(stats: stats)
        queue.push(.output(Data(repeating: 0x61, count: 10), colors: nil))
        _ = await queue.next()
        #expect(stats.snapshot().outputBytesCopiedApp == 10)
    }

    @Test func countersAddUpFromManyThreadsWithoutALock() {
        let stats = DaemonWireStats()
        let threads = 8
        let perThread = 10_000
        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            for _ in 0..<perThread {
                stats.lineRead(.event, handedOff: true)
                stats.bytesRead(3)
            }
        }
        let snapshot = stats.snapshot()
        let total = UInt64(threads * perThread)
        #expect(snapshot.linesRead == total)
        #expect(snapshot.framesRead[.event] == total)
        #expect(snapshot.envelopeDecodes == total)
        #expect(snapshot.consumerDecodes == total)
        #expect(snapshot.bytesRead == 3 * total)
        #expect(snapshot.decodesPerLine == 2)
    }

    @Test func resetZeroesTrafficButKeepsConnections() {
        let stats = DaemonWireStats()
        stats.connectionOpened(.terminalAttach, bridged: true)
        stats.connectionOpened(.control, bridged: false)
        stats.connectionClosed(.terminalAttach)
        stats.lineWritten(bytes: 12)
        stats.outputCopied(5)
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

/// A Unix socket served by this test process that speaks just enough raw protocol v12 for a control
/// connection and a byte-mode terminal attach: `identify` (after one line that is not JSON),
/// `ok:true` for every other request, and after each `attach-surface` reply `outputBytesPerAttach`
/// bytes of `output` events in 64 KiB chunks.
private final class FakeWireDaemon: Sendable {
    static let chunkBytes = 64 << 10

    let path: String
    private let listener: Int32
    private let outputBytesPerAttach: Int

    static func chunks(for bytes: Int) -> Int { (bytes + chunkBytes - 1) / chunkBytes }

    init(outputBytesPerAttach: Int) throws {
        path = "/tmp/cnd-wire-\(UUID().uuidString.prefix(8).lowercased()).sock"
        self.outputBytesPerAttach = outputBytesPerAttach
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
        let outputBytes = outputBytesPerAttach
        let thread = Thread {
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                let serving = Thread { Self.serve(client, outputBytes: outputBytes) }
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

    private static func serve(_ client: Int32, outputBytes: Int) {
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
                guard answer(command, id: id, request: request, to: client, outputBytes: outputBytes) else { return }
            }
        }
    }

    private static func answer(_ command: String, id: Int, request: [String: Any], to client: Int32, outputBytes: Int) -> Bool {
        switch command {
        case IdentifyRequest.command:
            let identity: [String: Any] = ["app": "cmux-tui", "protocol": 12, "generation": "gen-wire", "capabilities": [String]()]
            return write(Data("{]".utf8), to: client) && reply(id, data: identity, to: client)
        case AttachSurfaceRequest.command:
            guard reply(id, data: ["lease": "lease-\(id)"], to: client) else { return false }
            let surface = request["surface"] as? Int ?? 0
            var sent = 0
            while sent < outputBytes {
                let size = min(chunkBytes, outputBytes - sent)
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
