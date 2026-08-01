import Darwin
import Foundation

/// Thread-safe one-time descriptor transfer for connect dependency tests.
///
/// @unchecked Sendable is safe because the lock guards every access to the
/// mutable descriptor and ownership transfers exactly once.
final class OneShotSocketSource: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: Int32

    init(_ socket: Int32) {
        self.socket = socket
    }

    deinit {
        if socket >= 0 {
            Darwin.close(socket)
        }
    }

    func take() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard socket >= 0 else {
            Darwin.__error().pointee = EBADF
            return -1
        }
        let result = socket
        socket = -1
        return result
    }
}
