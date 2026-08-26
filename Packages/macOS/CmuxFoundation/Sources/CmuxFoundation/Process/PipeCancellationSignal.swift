import Darwin
import Foundation
import os

/// Close-on-exec pipe whose write-end closure interrupts both capture readers.
///
/// Safety: descriptor ownership never escapes this object and the lock-backed
/// endpoint state makes concurrent cancellation and final cleanup idempotent.
final class PipeCancellationSignal: @unchecked Sendable {
    let readDescriptor: Int32

    let writeDescriptor: Int32
    private let state = OSAllocatedUnfairLock(initialState: EndpointState())

    init() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else {
            throw Self.currentPOSIXError()
        }
        do {
            try Self.markCloseOnExec(descriptors[0])
            try Self.markCloseOnExec(descriptors[1])
        } catch {
            _ = Darwin.close(descriptors[0])
            _ = Darwin.close(descriptors[1])
            throw error
        }
        readDescriptor = descriptors[0]
        writeDescriptor = descriptors[1]
    }

    deinit {
        closeAll()
    }

    func cancelReaders() {
        let shouldClose = state.withLock { state -> Bool in
            guard state.isWriteOpen else { return false }
            state.isWriteOpen = false
            return true
        }
        if shouldClose {
            _ = Darwin.close(writeDescriptor)
        }
    }

    func closeAll() {
        cancelReaders()
        let shouldCloseRead = state.withLock { state -> Bool in
            guard state.isReadOpen else { return false }
            state.isReadOpen = false
            return true
        }
        if shouldCloseRead {
            _ = Darwin.close(readDescriptor)
        }
    }

    private static func markCloseOnExec(_ descriptor: Int32) throws {
        let flags = Darwin.fcntl(descriptor, F_GETFD)
        guard flags >= 0 else { throw currentPOSIXError() }
        guard Darwin.fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            throw currentPOSIXError()
        }
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private struct EndpointState: Sendable {
        var isReadOpen = true
        var isWriteOpen = true
    }
}
