import Foundation
import os
import Testing
@testable import CmuxNextDaemon

/// cmux-tui reserves a tab's attach slot while that attach connects to acpmux and refuses a second
/// attach of the same tab on the connection meanwhile (`agent_session.limit`, "too many attached
/// agent tabs", server/agent_session_attach.rs). The remote wire asks two at once (the page's
/// session list and its attach), so a Cloud machine's chat never connected: the client sends one
/// attach at a time.
@Suite(.timeLimit(.minutes(1))) struct AgentSessionAttachClientConcurrencyTests {
    @Test func turnSupportWaitsForThePendingAttachment() async throws {
        let signal = AsyncStream<Void>.makeStream()
        let daemon = try ReservingAttachDaemon(onAttach: { signal.continuation.yield(()); signal.continuation.finish() })
        defer { daemon.stop() }
        let client = AgentSessionAttachClient(surface: 7) { DaemonEndpoint(socketPath: daemon.path) }
        let pending = Task { try await client.attach(afterSeq: nil, beforeSeq: nil, limit: 1, kinds: nil) { _, _ in } }
        var events = signal.stream.makeAsyncIterator()
        _ = await events.next()
        #expect(try await client.supportsCloudTurns())
        _ = try await pending.value
        await client.close()
    }

    @Test func twoAttachesAskedTogetherBothAnswer() async throws {
        let daemon = try ReservingAttachDaemon()
        defer { daemon.stop() }
        let client = AgentSessionAttachClient(surface: 7) { DaemonEndpoint(socketPath: daemon.path) }
        async let list = client.attach(afterSeq: nil, beforeSeq: nil, limit: 1, kinds: ["transcript"]) { _, _ in }
        async let open = client.attach(afterSeq: nil, beforeSeq: nil, limit: 400, kinds: nil) { _, _ in }
        _ = try await (list, open)
        await client.close()
        #expect(daemon.refusals == 0)
        #expect(daemon.attaches == 2)
    }
}

/// A unix socket that answers `identify` and `set-client-info` at once and holds each
/// `agent-session-attach` for a moment, as cmux-tui does while it connects to acpmux: an attach
/// that arrives while another is held is refused `agent_session.limit`.
private nonisolated final class ReservingAttachDaemon: @unchecked Sendable {  // the fd is written once in init and closed once in stop
    let path: String
    private let descriptor: Int32
    private let onAttach: (@Sendable () -> Void)?
    private let counts = OSAllocatedUnfairLock<(attaches: Int, refusals: Int)>(initialState: (0, 0))
    var attaches: Int { counts.withLock { $0.attaches } }
    var refusals: Int { counts.withLock { $0.refusals } }

    init(onAttach: (@Sendable () -> Void)? = nil) throws {
        self.onAttach = onAttach
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("asc-\(UUID().uuidString.prefix(8)).sock").path
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
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                Thread.detachNewThread { self.serve(client) }
            }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        let reserved = OSAllocatedUnfairLock(initialState: false)
        let reply = { (object: [String: Any]) in
            guard var line = try? JSONSerialization.data(withJSONObject: object) else { return }
            line.append(0x0A)
            _ = line.withUnsafeBytes { send(client, $0.baseAddress, line.count, 0) }
        }
        let identity: [String: Any] = ["app": "cmux-tui", "protocol": 12, "generation": "boot-1",
                                       "capabilities": ["agent-session-attach-v1"]]
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
                let cmd = object["cmd"] as? String
                guard cmd == "agent-session-attach" else {
                    reply(["id": id, "ok": true, "data": cmd == "identify" ? identity : [:]])
                    continue
                }
                guard reserved.withLock({ held in defer { held = true }; return !held }) else {
                    counts.withLock { $0.refusals += 1 }
                    reply(["id": id, "ok": false, "error": "too many attached agent tabs", "error_code": "agent_session.limit"])
                    continue
                }
                counts.withLock { $0.attaches += 1 }
                onAttach?()
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(300)) {
                    reserved.withLock { $0 = false }
                    reply(["id": id, "ok": true, "data": ["session": ["sessionId": "s1"], "events": [Any](), "cloud_turn_supported": true]])
                }
            }
        }
    }

    func stop() {
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
        unlink(path)
    }
}
