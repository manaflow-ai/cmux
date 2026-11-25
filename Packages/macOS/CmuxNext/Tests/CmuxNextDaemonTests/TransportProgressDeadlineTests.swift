import CmuxNextCompat
import Darwin
import Foundation
import Testing
@testable import CmuxNextDaemon

/// A daemon request's deadline is silence on its connection, not time since it was sent (Leo, 2026-11-24:
/// "10s timeout for messages being sendsble is a shame. if it's making good progress, it shiukd be allowed
/// to keep going?"). Before, a 10 MiB terminal replay or a prompt with a large image over a slow link failed at
/// the bound while its bytes were still arriving.
@Suite(.timeLimit(.minutes(1))) struct TransportProgressDeadlineTests {
    @Test func theBoundCountsFromTheLatestProgress() {
        let start = ContinuousClock.now
        let quiet = Duration.seconds(10)
        // Nothing moved: the bound counts from the arm.
        #expect(TransportProgress.remaining(quiet: quiet, armedAt: start, lastProgress: start - .seconds(60), now: start + .seconds(4)) == .seconds(6))
        #expect(TransportProgress.remaining(quiet: quiet, armedAt: start, lastProgress: start - .seconds(60), now: start + .seconds(10)) == nil)
        // Bytes moved at 9 s: at 15 s, 4 s are left, though 15 s passed since the send.
        #expect(TransportProgress.remaining(quiet: quiet, armedAt: start, lastProgress: start + .seconds(9), now: start + .seconds(15)) == .seconds(4))
        #expect(TransportProgress.remaining(quiet: quiet, armedAt: start, lastProgress: start + .seconds(9), now: start + .seconds(19)) == nil)
    }

    @Test func progressNeverMovesBack() {
        let start = ContinuousClock.now
        let progress = TransportProgress(now: start)
        progress.note(at: start + .seconds(5))
        progress.note(at: start + .seconds(2))
        #expect(progress.lastAt == start + .seconds(5))
    }

    @Test func aReplyStillArrivingPastTheBoundIsNotCutOff() async throws {
        let daemon = try DribblingDaemon()
        defer { daemon.stop() }
        let transport = try LineTransport(path: daemon.path)
        defer { transport.close() }
        transport.start(onEvent: { _, _, _ in }, onClose: { _ in })
        // A 600 ms silence bound, and a reply that takes about 2.4 s to arrive, a slice every 200 ms.
        let reply = Task {
            try await transport.request(cmd: "attach-surface", timeout: .milliseconds(600)) { id in
                Data(#"{"id":\#(id),"cmd":"attach-surface"}"#.utf8)
            }
        }
        let id = try #require(await daemon.firstRequest())
        let line = Data(#"{"id":\#(id),"ok":true,"data":{"replay":"\#(String(repeating: "x", count: 12_000))"}}"#.utf8) + Data([0x0A])
        daemon.send(line, slices: 12, every: .milliseconds(200))
        let response = try await reply.value
        #expect(response.line.count == line.count - 1, "the whole reply arrived")
    }

    @Test func aSilentDaemonStillTimesOut() async throws {
        let daemon = try DribblingDaemon()
        defer { daemon.stop() }
        let transport = try LineTransport(path: daemon.path)
        defer { transport.close() }
        transport.start(onEvent: { _, _, _ in }, onClose: { _ in })
        let result = await Task {
            try await transport.request(cmd: "attach-surface", timeout: .milliseconds(300)) { id in
                Data(#"{"id":\#(id),"cmd":"attach-surface"}"#.utf8)
            }
        }.result
        guard case .failure(let failure) = result, let error = failure as? DaemonError, case .timedOut = error else {
            Issue.record("a daemon that sends nothing must still fail the request: \(result)")
            return
        }
    }
}

/// A unix socket served by a thread of the test process: it records the first request's id and answers only
/// when told, in slices with a pause between them.
nonisolated final class DribblingDaemon: @unchecked Sendable {  // the fds are written once in init and closed once in stop
    let path: String
    private let descriptor: Int32
    private let state = Mutex<(client: Int32, id: Int)?>(nil)

    init() throws {
        path = "/tmp/dd-\(UUID().uuidString.prefix(8)).sock"
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
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            serve(client)
        }
    }

    private func serve(_ client: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(client, &chunk, chunk.count, 0)
            guard count > 0 else { return }
            buffer += Data(chunk[0..<count])
            guard let newline = buffer.firstIndex(of: 0x0A) else { continue }
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = object["id"] as? Int {
                state.withLock { if $0 == nil { $0 = (client, id) } }
            }
        }
    }

    /// The first request's id, once it came (polls at most 10 s).
    func firstRequest() async -> Int? {
        for _ in 0..<1000 {
            if let held = state.withLock({ $0 }) { return held.id }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// Writes `bytes` to the first request's client in `slices` parts, `every` apart, on a thread of its own.
    func send(_ bytes: Data, slices: Int, every pause: Duration) {
        guard let client = state.withLock({ $0?.client }) else { return }
        let size = (bytes.count + slices - 1) / slices
        Thread.detachNewThread {
            var offset = 0
            while offset < bytes.count {
                let part = bytes.subdata(in: offset..<min(offset + size, bytes.count))
                _ = part.withUnsafeBytes { Darwin.send(client, $0.baseAddress, part.count, 0) }
                offset += size
                if offset < bytes.count { Thread.sleep(forTimeInterval: Double(pause.components.attoseconds) / 1e18 + Double(pause.components.seconds)) }
            }
        }
    }

    func stop() {
        if let client = state.withLock({ $0?.client }) { close(client) }
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
        unlink(path)
    }
}
