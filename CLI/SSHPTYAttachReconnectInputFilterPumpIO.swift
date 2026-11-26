import Darwin
import Foundation

extension SSHPTYAttachReconnectInputFilter {
    static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var remaining = rawBuffer.count
            var cursor = base
            while remaining > 0 {
                let written = Darwin.write(fd, cursor, remaining)
                if written > 0 {
                    remaining -= written
                    cursor = cursor.advanced(by: written)
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    throw POSIXError(.EIO)
                }
            }
        }
    }

    static func pollStdinPump(
        inputFD: Int32,
        stopSignalFD: Int32?,
        timeoutMilliseconds: Int32
    ) -> (inputReady: Bool, stopRequested: Bool)? {
        let inputEvents = Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL)
        let stopEvents = Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL)
        var pollFDs = [pollfd(fd: inputFD, events: Int16(POLLIN), revents: 0)]
        if let stopSignalFD {
            pollFDs.append(pollfd(fd: stopSignalFD, events: Int16(POLLIN), revents: 0))
        }

        // Anchor the timeout to an absolute monotonic deadline so EINTR
        // retries cannot extend the caller's window (e.g. the reconnect
        // filter deadline) under repeated signal delivery.
        let deadline: DispatchTime? = timeoutMilliseconds >= 0
            ? .now() + .milliseconds(Int(timeoutMilliseconds))
            : nil
        var remainingTimeout = timeoutMilliseconds
        while true {
            let result = pollFDs.withUnsafeMutableBufferPointer { buffer in
                Darwin.poll(buffer.baseAddress, nfds_t(buffer.count), remainingTimeout)
            }
            if result > 0 {
                let inputReady = (pollFDs[0].revents & inputEvents) != 0
                let stopRequested = pollFDs.count > 1 && (pollFDs[1].revents & stopEvents) != 0
                return (inputReady: inputReady, stopRequested: stopRequested)
            }
            if result == 0 {
                return (inputReady: false, stopRequested: false)
            }
            if errno == EINTR {
                if let deadline {
                    let now = DispatchTime.now()
                    guard now < deadline else {
                        return (inputReady: false, stopRequested: false)
                    }
                    let remainingNanos = deadline.uptimeNanoseconds - now.uptimeNanoseconds
                    remainingTimeout = Int32(min(Int64(Int32.max), Int64(remainingNanos / 1_000_000) + 1))
                }
                continue
            }
            return nil
        }
    }
}
