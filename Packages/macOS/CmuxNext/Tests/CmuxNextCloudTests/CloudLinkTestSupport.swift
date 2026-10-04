@testable import CmuxNextCloud
import Darwin
import Foundation
import Synchronization

/// A listening Unix socket in a new owner-only directory under /tmp (short
/// enough for sun_path). Removed by `remove()`.
struct TestLinkSocket {
    let directory: String
    let path: String
    private let fd: Int32

    init(directoryMode: mode_t = 0o700) throws {
        let directory = "/tmp/c13-\(UUID().uuidString.prefix(8))"
        guard mkdir(directory, 0o700) == 0, chmod(directory, directoryMode) == 0 else { throw POSIXError(.EIO) }
        self.directory = directory
        path = directory + "/l.sock"
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 1) == 0 else { throw POSIXError(.EADDRINUSE) }
    }

    func remove() {
        close(fd)
        unlink(path)
        rmdir(directory)
    }
}

/// Records every Cloud app op and answers from a script.
final class FakeCloudAppOps: Sendable {
    struct Call: Equatable, Sendable {
        var op: String
        var args: [String: String]
        var key: String
        var origin: CloudLinkOrigin
    }

    private let calls = Mutex<[Call]>([])
    private let answer: @Sendable (Call) throws -> Data

    init(answer: @escaping @Sendable (Call) throws -> Data) {
        self.answer = answer
    }

    /// Answers `cloud.machine.connect` with an up carrier on `socket`.
    convenience init(socket: String, generation: UInt64 = 1) {
        self.init { call in
            let machine = call.args["machine"] ?? ""
            return Data(#"{"machine":"\#(machine)","carrier":"c1","generation":\#(generation),"state":"up","socket":"\#(socket)"}"#.utf8)
        }
    }

    var recorded: [Call] { calls.withLock { $0 } }

    var runner: CloudAppOpRunner {
        { op, args, key, origin in
            let call = Call(op: op, args: args, key: key, origin: origin)
            self.calls.withLock { $0.append(call) }
            return try self.answer(call)
        }
    }
}
