import CmuxNextCompat
import Darwin
import Foundation
import Testing
@testable import CmuxNextDaemon

/// P0 2026-10-30 (v2.2.10-opt, "I can't even make new workspaces"): under swap the app's control
/// connection read no reply for a while, the heartbeat's two unanswered `identify` asks closed it
/// (`LineTransport.close()`), and every request on it failed "cmux-tui connection closed: closed
/// by client": 9 creates, 36 window saves, the trail. The daemon was alive and answered nothing late
/// on its side (registry wait p99 0). A client clock must not end a live daemon's connection: a slow
/// reply is waited for on the same connection; only a real signal (EOF, an error, the daemon process
/// gone) ends it.
@Suite(.timeLimit(.minutes(1))) struct HeartbeatLiveDaemonTests {
    /// The daemon (a thread of this process, so its process is alive) reads every request and
    /// answers none until released. The heartbeat asks again and again; the create sent before it
    /// must still get its reply once the daemon answers, on the same connection.
    @Test func unansweredAsksDoNotCloseALiveDaemonsConnectionOrFailACreate() async throws {
        let daemon = try SlowDaemon()
        defer { daemon.stop() }
        let transport = try LineTransport(path: daemon.path)
        defer { transport.close() }
        let closes = Mutex<[TransportCloseReason]>([])
        transport.start(onEvent: { _, _, _ in }, onClose: { reason in closes.withLock { $0.append(reason) } })
        let heartbeat = ConnectionHeartbeat()
        heartbeat.start(transport, every: .milliseconds(40), misses: 2)
        defer { heartbeat.stop() }

        // A create has no client deadline (it waits for the daemon's reply), as `new-tab` does.
        let create = Task {
            try await transport.request(cmd: "create-workspace", timeout: nil) { id in
                Data(#"{"id":\#(id),"cmd":"create-workspace"}"#.utf8)
            }
        }
        // Past two misses (the old close) the heartbeat must still be asking on this connection; a closed
        // connection asks nothing more and the daemon reads EOF.
        let outcome = await daemon.waitForAsks(4)
        #expect(outcome == .asked, "the heartbeat closed a live daemon's connection after its misses (\(outcome))")
        #expect(!transport.isClosed, "the transport was closed while the daemon process was alive")
        #expect(!heartbeat.answering, "past its misses the heartbeat must say the daemon does not answer")

        daemon.answerEverything()
        let reply = await create.result
        switch reply {
        case .success: break
        case .failure(let error): Issue.record("the create failed while the daemon was alive: \(error)")
        }
        #expect(closes.withLock { $0 }.isEmpty, "the connection ended: \(closes.withLock { $0 })")
        var answeringAgain = false
        for _ in 0..<500 where !answeringAgain {
            answeringAgain = heartbeat.answering
            if !answeringAgain { try? await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(answeringAgain, "the daemon answers again but the heartbeat still says it does not")
    }
}

/// A unix socket served by a thread of the test process: it records every request and answers none
/// until ``answerEverything()``, then answers each one (those read so far and later ones) `ok`.
nonisolated final class SlowDaemon: @unchecked Sendable {  // the fd is written once in init and closed once in stop
    enum Outcome: Equatable { case asked, closed, timedOut }

    let path: String
    private let descriptor: Int32
    private struct State {
        var unanswered: [(client: Int32, id: Int)] = []
        var answering = false
        var identifyAsks = 0
        var sawEOF = false
    }
    private let state = Mutex(State())

    init() throws {
        path = "/tmp/hb-\(UUID().uuidString.prefix(8)).sock"
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
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(client, &chunk, chunk.count, 0)
            guard count > 0 else {
                state.withLock { $0.sawEOF = true }
                return
            }
            buffer += Data(chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = object["id"] as? Int else { continue }
                let answerNow = state.withLock { state -> Bool in
                    if object["cmd"] as? String == "identify" { state.identifyAsks += 1 }
                    guard state.answering else {
                        state.unanswered.append((client, id))
                        return false
                    }
                    return true
                }
                if answerNow { Self.answer(id, on: client) }
            }
        }
    }

    private static func answer(_ id: Int, on client: Int32) {
        guard var reply = try? JSONSerialization.data(withJSONObject: ["id": id, "ok": true, "data": [String: Any]()]) else { return }
        reply.append(0x0A)
        _ = reply.withUnsafeBytes { send(client, $0.baseAddress, reply.count, 0) }
    }

    /// Waits (polling the recorded state, at most 10 s) until `count` identify asks came, or the connection ended.
    func waitForAsks(_ count: Int) async -> Outcome {
        for _ in 0..<1000 {
            let (asks, eof) = state.withLock { ($0.identifyAsks, $0.sawEOF) }
            if eof { return .closed }
            if asks >= count { return .asked }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return .timedOut
    }

    func answerEverything() {
        let pending = state.withLock { state -> [(client: Int32, id: Int)] in
            state.answering = true
            defer { state.unanswered = [] }
            return state.unanswered
        }
        for request in pending { Self.answer(request.id, on: request.client) }
    }

    func stop() {
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
        unlink(path)
    }
}
