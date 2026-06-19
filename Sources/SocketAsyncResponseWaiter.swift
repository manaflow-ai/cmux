import Darwin
import Foundation

/// One-shot file-descriptor wake for main-actor async socket replies.
///
/// The control socket still has a synchronous, line-in/line-out contract on a
/// dedicated client thread. Auth commands need main-actor async work, so the
/// main-actor task writes one byte to this pipe when the encoded response is
/// ready; the client thread owns the blocking read and final socket write.
nonisolated final class SocketAsyncResponseWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private let readFD: Int32
    private let writeFD: Int32
    private var response: String?

    init?() {
        var fds = [Int32](repeating: -1, count: 2)
        guard pipe(&fds) == 0 else { return nil }
        readFD = fds[0]
        writeFD = fds[1]
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)
    }

    deinit {
        close(readFD)
        close(writeFD)
    }

    func complete(_ response: String) {
        lock.lock()
        self.response = response
        lock.unlock()

        var byte: UInt8 = 1
        _ = Darwin.write(writeFD, &byte, 1)
    }

    func wait() -> String? {
        var byte: UInt8 = 0
        while true {
            let result = Darwin.read(readFD, &byte, 1)
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { return nil }
            lock.lock()
            let current = response
            lock.unlock()
            return current
        }
    }
}
