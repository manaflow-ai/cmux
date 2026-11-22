import CmuxNextDaemon
import Foundation
import Synchronization

/// A Unix socket that answers cmux-tui requests from a handler, for App
/// tests of remote daemons (a Cloud machine's link socket forwards lines
/// unchanged, so this is what the App sees).
nonisolated final class ScriptedDaemonSocket: Sendable {
    let path: String
    private let listenFD: Int32
    private let clients = Clients()

    private final class Clients: Sendable {
        let fds = Mutex<[Int32]>([])
    }

    init(handler: @escaping @Sendable (_ request: [String: JSONValue]) -> [String]) throws {
        let path = "/tmp/cna-\(UUID().uuidString.prefix(8)).sock"
        self.path = path
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8)
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { throw DaemonError.connectFailed(path: path, errno: errno) }
        listenFD = fd
        let clients = clients
        Thread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                clients.fds.withLock { $0.append(client) }
                Thread { Self.serve(client, handler: handler) }.start()
            }
        }.start()
    }

    private static func serve(_ client: Int32, handler: @Sendable ([String: JSONValue]) -> [String]) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(client, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard case .object(let request)? = try? JSONDecoder().decode(JSONValue.self, from: Data(line)) else { continue }
                for reply in handler(request) {
                    let bytes = Array((reply + "\n").utf8)
                    _ = bytes.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                }
            }
        }
    }

    func stop() {
        clients.fds.withLock { fds in
            for fd in fds { shutdown(fd, SHUT_RDWR); close(fd) }
            fds.removeAll()
        }
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
        unlink(path)
    }
}
