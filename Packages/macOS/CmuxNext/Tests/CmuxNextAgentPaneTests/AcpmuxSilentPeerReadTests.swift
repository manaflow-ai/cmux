import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The app's real line (``AcpmuxPersonLine``) against an acpmux whose `_acpmux/info` never
/// answers, as a peer that stalls on every recovery. A recovery that finds that session's read
/// still outstanding joins it rather than asking again: 100 recoveries hold one read on the line,
/// not one more each time.
@MainActor @Suite(.serialized) struct AcpmuxSilentPeerReadTests {
    @Test func aSilentPeerHoldsAtMostOneReplyOnTheLineAfter100Recoveries() async throws {
        let socket = "/tmp/aspr-\(UUID().uuidString.prefix(8))/acpmux.sock"
        let daemon = try SilentAcpmux(socket: socket)
        defer { daemon.stop() }
        // The line lives far past the test: nothing it closes gives a read back.
        let line = try #require(await AcpmuxPersonLine.open(try Self.environment(socket), deadline: .seconds(120)))
        let reads = AcpmuxPendingReads(width: 4, deadline: .milliseconds(5))
        let rows: [[String: Any]] = [["sessionId": "acp_peer_silent", "peer": "peer-a"]]
        let count = Count()
        for _ in 0..<100 {
            _ = await reads.pending(of: rows) { session in
                count.asked += 1
                let reply = await line.call("_acpmux/info", ["sessionId": session])
                count.answered += 1
                return reply
            }
        }
        let outstanding = count.asked - count.answered
        line.close()
        #expect(count.asked == 1, "each recovery after the first asked again (\(count.asked) reads)")
        #expect(outstanding <= 1, "\(outstanding) info reads still wait on the line after 100 recoveries")
    }

    /// The info reads asked on the line, and those that came back.
    @MainActor final class Count {
        var asked = 0
        var answered = 0
    }

    /// The test process is the server peer the line checks for: the fake runs in it.
    private static func environment(_ socket: String) throws -> AcpmuxEnvironment {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        try #require(proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0)
        let executable = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        let home = URL(fileURLWithPath: (socket as NSString).deletingLastPathComponent, isDirectory: true)
        return AcpmuxEnvironment(executable: executable, home: home, socketPath: socket, daemonArguments: [], childEnvironment: [:])
    }

    /// acpmux on a unix socket for one connection: it answers `initialize` and never answers
    /// anything else. The connection ends when the line closes (each read bounded at 30 s).
    nonisolated final class SilentAcpmux: @unchecked Sendable { // crash-allow: fields are set once in init
        private let listener: Int32
        private let directory: String
        private let done = DispatchSemaphore(value: 0)

        init(socket: String) throws {
            directory = (socket as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let path = Array(socket.utf8CString)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in path.withUnsafeBytes { buffer.copyMemory(from: $0) } }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, listen(fd, 4) == 0 else {
                close(fd)
                throw POSIXError(.EADDRINUSE)
            }
            listener = fd
            Thread.detachNewThread { [self] in
                serve()
                done.signal()
            }
        }

        func stop() {
            _ = done.wait(timeout: .now() + 35)
            close(listener)
            try? FileManager.default.removeItem(atPath: directory)
        }

        private func serve() {
            var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, 10_000) == 1 else { return }
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            defer { close(fd) }
            var timeout = timeval(tv_sec: 30, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = recv(fd, &chunk, chunk.count, 0)
                guard count > 0 else { return }
                buffer.append(contentsOf: chunk[0..<count])
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                          let id = request["id"], request["method"] as? String == "initialize" else { continue }
                    let reply: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": ["_meta": ["acpmux": ["capabilities": ["acpmux-v1"]]]]]
                    guard var frame = try? JSONSerialization.data(withJSONObject: reply) else { return }
                    frame.append(0x0A)
                    _ = frame.withUnsafeBytes { send(fd, $0.baseAddress, frame.count, 0) }
                }
            }
        }
    }
}
