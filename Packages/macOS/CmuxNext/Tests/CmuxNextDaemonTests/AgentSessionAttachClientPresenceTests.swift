import Foundation
import Testing
import CmuxNextCompat
@testable import CmuxNextDaemon

/// `agent-session-presence-v1` over a real daemon line socket: a daemon that lists it gets the
/// typing and view verbs and the client's echo in `set-client-info` (so it streams presence); one
/// that does not gets neither verb and no echo, so an older daemon sees nothing new.
@Suite(.timeLimit(.minutes(1))) struct AgentSessionAttachClientPresenceTests {
    @Test func aDaemonWithPresenceGetsTypingViewAndTheEcho() async throws {
        let daemon = try PresenceDaemon(capabilities: ["agent-session-attach-v1", "agent-session-presence-v1"])
        defer { daemon.stop() }
        let client = AgentSessionAttachClient(surface: 7) { DaemonEndpoint(socketPath: daemon.path) }
        try await client.typing(true)
        try await client.view(false)
        await client.close()
        let sent = daemon.frames
        #expect(sent.map { $0["cmd"] as? String } == ["identify", "set-client-info", "agent-session-typing", "agent-session-view"])
        #expect(sent[1]["capabilities"] as? [String] == ["agent-session-presence-v1"])
        #expect(sent[2]["on"] as? Bool == true && sent[2]["surface"] as? Int == 7)
        #expect(sent[3]["visible"] as? Bool == false)
    }

    @Test func anOlderDaemonGetsNoNewVerbAndNoEcho() async throws {
        let daemon = try PresenceDaemon(capabilities: ["agent-session-attach-v1"])
        defer { daemon.stop() }
        let client = AgentSessionAttachClient(surface: 7) { DaemonEndpoint(socketPath: daemon.path) }
        try await client.typing(true)
        try await client.view(true)
        await client.close()
        let sent = daemon.frames
        #expect(sent.map { $0["cmd"] as? String } == ["identify", "set-client-info"])
        #expect((sent[1]["capabilities"] as? [String] ?? []).isEmpty)
    }

    /// The bundled daemon serves it, and only the attach client echoes it: every other connection's
    /// `set-client-info` leaves it out, so presence never streams to a connection that draws none.
    @Test func onlyTheAttachClientEchoesPresence() {
        let name = DaemonCapability.agentSessionPresence.rawValue
        #expect(DaemonCapability.isServedByBundledDaemon(name))
        #expect(DaemonCapability.optional.contains(name))
        #expect(!DaemonCapability.advertised.contains(name))
        #expect(!DaemonCapability.handshakeCapabilities(DaemonCapability.advertised, resolvesShellIntegration: true,
                                                        echoesPlacementShift: true).contains(name))
    }
}

/// A unix socket that answers `identify` with `capabilities` and every other command `ok`, and
/// records each request.
private nonisolated final class PresenceDaemon: @unchecked Sendable {  // the fd is written once in init and closed once in stop
    let path: String
    private let descriptor: Int32
    private let recorded = Mutex<[Data]>([])
    var frames: [[String: Any]] {
        recorded.withLock { $0 }.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    init(capabilities: [String]) throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("asp-\(UUID().uuidString.prefix(8)).sock").path
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = path
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else { throw POSIXError(.EADDRINUSE) }
        let identity: [String: Any] = ["app": "cmux-tui", "protocol": 12, "generation": "boot-1", "capabilities": capabilities]
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                Thread.detachNewThread { self.serve(client, identity: identity) }
            }
        }
    }

    private func serve(_ client: Int32, identity: [String: Any]) {
        defer { close(client) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(client, &chunk, chunk.count, 0)
            guard count > 0 else { return }
            buffer += Data(chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = object["id"] else { continue }
                recorded.withLock { $0.append(line) }
                let data: [String: Any] = object["cmd"] as? String == "identify" ? identity : [:]
                guard var reply = try? JSONSerialization.data(withJSONObject: ["id": id, "ok": true, "data": data]) else { continue }
                reply.append(0x0A)
                _ = reply.withUnsafeBytes { send(client, $0.baseAddress, reply.count, 0) }
            }
        }
    }

    func stop() {
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
        unlink(path)
    }
}
