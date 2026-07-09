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

        while true {
            let result = pollFDs.withUnsafeMutableBufferPointer { buffer in
                Darwin.poll(buffer.baseAddress, nfds_t(buffer.count), timeoutMilliseconds)
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
                continue
            }
            return nil
        }
    }
}
