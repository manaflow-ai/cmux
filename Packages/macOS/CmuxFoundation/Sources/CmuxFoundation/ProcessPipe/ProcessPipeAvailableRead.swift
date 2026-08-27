import Darwin
public import Foundation

/// The outcome of one non-blocking read attempt against a pipe or socket
/// descriptor.
public enum ProcessPipeAvailableRead: Equatable, Sendable {
    /// Bytes were available and read.
    case data(Data)
    /// No bytes are buffered but the writer is still open.
    case wouldBlock
    /// The writer closed; no further bytes will arrive.
    case endOfFile
}

extension ProcessPipeAvailableRead {
    // The raw descriptor read loops live on this type (the value they
    // produce) rather than as free functions, per the no-free-functions
    // convention. They are internal: callers go through the FileHandle
    // surface in FileHandle+ProcessPipeReading.swift.

    /// One blocking `read(2)`, retrying `EINTR`. An empty `Data` means EOF.
    static func readOnce(
        fileDescriptor: Int32,
        maxLength: Int,
        operation: String
    ) -> Result<Data, ProcessPipeReadError> {
        guard maxLength > 0 else { return .success(Data()) }

        var buffer = [UInt8](repeating: 0, count: maxLength)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let baseAddress = pointer.baseAddress else { return 0 }
                return Darwin.read(fileDescriptor, baseAddress, maxLength)
            }

            if bytesRead > 0 {
                return .success(Data(buffer.prefix(bytesRead)))
            }
            if bytesRead == 0 {
                return .success(Data())
            }

            let code = errno
            if code == EINTR {
                continue
            }
            return .failure(ProcessPipeReadError(operation: operation, errnoCode: code))
        }
    }

    /// One `read(2)` that maps `EAGAIN`/`EWOULDBLOCK` to ``wouldBlock``,
    /// retrying `EINTR`.
    static func readAvailableOnce(
        fileDescriptor: Int32,
        maxLength: Int,
        operation: String
    ) -> Result<ProcessPipeAvailableRead, ProcessPipeReadError> {
        guard maxLength > 0 else { return .success(.wouldBlock) }

        var buffer = [UInt8](repeating: 0, count: maxLength)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let baseAddress = pointer.baseAddress else { return 0 }
                return Darwin.read(fileDescriptor, baseAddress, maxLength)
            }

            if bytesRead > 0 {
                return .success(.data(Data(buffer.prefix(bytesRead))))
            }
            if bytesRead == 0 {
                return .success(.endOfFile)
            }

            let code = errno
            if code == EINTR {
                continue
            }
            if code == EAGAIN || code == EWOULDBLOCK {
                return .success(.wouldBlock)
            }
            return .failure(ProcessPipeReadError(operation: operation, errnoCode: code))
        }
    }

    /// `poll(2)` for readability first, then read, so a blocking descriptor
    /// with an open writer reports ``wouldBlock`` instead of stalling.
    static func readOnceIfReady(
        fileDescriptor: Int32,
        maxLength: Int,
        operation: String
    ) -> Result<ProcessPipeAvailableRead, ProcessPipeReadError> {
        guard maxLength > 0 else { return .success(.wouldBlock) }

        // Do not toggle O_NONBLOCK here. The flag lives on the open file description,
        // so changing it can affect concurrent writers that share a socket fd.
        var descriptor = pollfd(
            fd: fileDescriptor,
            events: Int16(POLLIN | POLLERR | POLLHUP),
            revents: 0
        )
        while true {
            let pollResult = Darwin.poll(&descriptor, 1, 0)
            if pollResult > 0 {
                break
            }
            if pollResult == 0 {
                return .success(.wouldBlock)
            }

            let code = errno
            if code == EINTR {
                continue
            }
            return .failure(ProcessPipeReadError(
                operation: "\(operation).poll",
                errnoCode: code
            ))
        }

        if (descriptor.revents & Int16(POLLNVAL)) != 0 {
            return .failure(ProcessPipeReadError(
                operation: "\(operation).poll",
                errnoCode: EBADF
            ))
        }

        guard (descriptor.revents & Int16(POLLIN | POLLERR | POLLHUP)) != 0 else {
            return .success(.wouldBlock)
        }

        return readAvailableOnce(
            fileDescriptor: fileDescriptor,
            maxLength: maxLength,
            operation: operation
        )
    }
}
