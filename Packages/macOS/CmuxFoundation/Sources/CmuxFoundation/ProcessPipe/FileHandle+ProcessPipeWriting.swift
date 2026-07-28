import Darwin
public import Foundation

extension FileHandle {
    /// Writes every byte to a child-process pipe without allowing `SIGPIPE` to terminate the process.
    ///
    /// Unlike Foundation's legacy nonthrowing write APIs, a closed reader is
    /// reported as a ``POSIXError``. Partial writes and interrupted system
    /// calls are completed before this method returns.
    ///
    /// - Parameter data: The bytes to write to the pipe.
    /// - Throws: A ``POSIXError`` when configuring or writing the descriptor fails.
    public func writeProcessPipeInput(_ data: Data) throws {
        let descriptor = fileDescriptor
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written > 0 {
                    offset += written
                    continue
                }

                let code = written == 0 ? EIO : errno
                if code == EINTR {
                    continue
                }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        }
    }
}
