import Foundation

/// A stand-in relay admin socket: answers each request line of a connection with the next of `replies`.
/// Shared by the add-account and inline /btw tests; it lived in LocalRouterLongHomeTests until #57508 deleted that file.
nonisolated final class OneShotRelay: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private let replies: [Array<UInt8>]
    private let lock = NSLock()
    private var received: [String] = []

    var requests: [String] { lock.withLock { received } }

    /// Wait until a request containing `needle` has been recorded. Network.framework may
    /// deliver the reply before the relay thread gets scheduled to publish its observation.
    func waitForRequest(containing needle: String, timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if recorded(containing: needle) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return recorded(containing: needle)
    }

    /// JSONSerialization writes `/` as `\/`, so a method such as `_acpmux/btw` is matched on
    /// the unescaped text.
    private func recorded(containing needle: String) -> Bool {
        requests.contains { $0.replacingOccurrences(of: #"\/"#, with: "/").contains(needle) }
    }

    convenience init(path: String, reply: String) throws {
        try self.init(path: path, replies: [reply])
    }

    init(path: String, replies: [String]) throws {
        self.path = path
        unlink(path)
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        listener = server
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(server, 4) == 0 else { throw POSIXError(.EADDRINUSE) }
        self.replies = replies.map { Array(($0 + "\n").utf8) }
        let answers = self.replies
        Thread.detachNewThread {
            while true {
                let fd = accept(server, nil, nil)
                guard fd >= 0 else { return }
                for answer in answers {
                    var line = Data()
                    var byte: UInt8 = 0
                    while read(fd, &byte, 1) == 1, byte != 0x0A { line.append(byte) }
                    if let request = String(data: line, encoding: .utf8) { self.lock.withLock { self.received.append(request) } }
                    _ = answer.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                }
                close(fd)
            }
        }
    }

    func stop() {
        _ = shutdown(listener, SHUT_RDWR)  // wakes the accept thread
        close(listener)
        unlink(path)
    }
}
