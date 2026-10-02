import Darwin
import Foundation
import os

/// A Foundation `Pipe` whose endpoints are close-on-exec and explicitly owned.
///
/// Safety: the pipe is configured before publication and the lock-backed
/// endpoint state makes cleanup idempotent across lifecycle callbacks.
final class OwnedProcessPipe: @unchecked Sendable {
    let pipe: Pipe

    private let state = OSAllocatedUnfairLock(initialState: EndpointState())

    init() throws {
        pipe = Pipe()
        do {
            try Self.markCloseOnExec(pipe.fileHandleForReading.fileDescriptor)
            try Self.markCloseOnExec(pipe.fileHandleForWriting.fileDescriptor)
        } catch {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
            throw error
        }
    }

    deinit {
        closeAll()
    }

    func closeAll() {
        let endpoints = state.withLock { state -> (Bool, Bool) in
            let endpoints = (state.isReadOpen, state.isWriteOpen)
            state.isReadOpen = false
            state.isWriteOpen = false
            return endpoints
        }
        if endpoints.0 {
            try? pipe.fileHandleForReading.close()
        }
        if endpoints.1 {
            try? pipe.fileHandleForWriting.close()
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
