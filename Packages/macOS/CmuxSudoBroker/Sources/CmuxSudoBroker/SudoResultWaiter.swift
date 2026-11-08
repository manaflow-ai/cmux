import Darwin
import Foundation

struct SudoResultWaiter {
    private let store: SudoSpoolStore
    private let io: SudoCLIIO

    init(store: SudoSpoolStore, io: SudoCLIIO) {
        self.store = store
        self.io = io
    }

    func wait(
        requestID: String,
        deadline: Date,
        approvalTimeoutNote: String
    ) throws -> SudoResultWaitOutcome {
        let leaseDescriptor = try store.acquireResultLease(id: requestID)
        defer { store.releaseResultLease(id: requestID, descriptor: leaseDescriptor) }
        // Reconcile a broker crash before arming the waiter. This also makes a
        // committed result observable when the app exited during archival. The
        // lease is held first so maintenance cannot prune this waiter's output.
        try store.ensureDirectories()
        var outputDescriptor: Int32 = -1
        defer {
            if outputDescriptor >= 0 { close(outputDescriptor) }
        }

        let queue = kqueue()
        guard queue >= 0 else { throw SudoResultWaitError.queue(errno) }
        defer { close(queue) }

        let watchedDirectories = [
            store.paths.results,
            store.paths.requests,
            store.paths.states,
        ].map { directory in
            Darwin.open(directory.path, O_EVTONLY | O_CLOEXEC)
        }
        guard watchedDirectories.allSatisfy({ $0 >= 0 }) else {
            for descriptor in watchedDirectories where descriptor >= 0 { close(descriptor) }
            throw SudoResultWaitError.directory(errno)
        }
        defer {
            for descriptor in watchedDirectories { close(descriptor) }
        }
        for descriptor in watchedDirectories {
            try registerVnode(descriptor: descriptor, queue: queue)
        }

        let timerIdentifier = UInt.max
        let remainingSeconds = max(0, deadline.timeIntervalSinceNow)
        let milliseconds = SudoKeventTimeout(seconds: remainingSeconds).milliseconds
        var timerEvent = kevent(
            ident: timerIdentifier,
            filter: Int16(EVFILT_TIMER),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: 0,
            data: milliseconds,
            udata: nil
        )
        guard kevent(queue, &timerEvent, 1, nil, 0, nil) == 0 else {
            throw SudoResultWaitError.timer(errno)
        }

        while true {
            try openOutputIfAvailable(
                requestID: requestID,
                queue: queue,
                descriptor: &outputDescriptor
            )
            try drainOutput(descriptor: outputDescriptor)
            if let result = store.authoritativeResult(id: requestID) {
                try drainOutput(descriptor: outputDescriptor)
                store.removeOutput(id: requestID)
                return .result(result)
            }
            if remainingSeconds <= 0 {
                return try settleTimeout(
                    requestID: requestID,
                    note: approvalTimeoutNote
                )
            }

            var event = kevent()
            let result = kevent(queue, nil, 0, &event, 1, nil)
            if result > 0 {
                if event.filter == Int16(EVFILT_TIMER), event.ident == timerIdentifier {
                    try openOutputIfAvailable(
                        requestID: requestID,
                        queue: queue,
                        descriptor: &outputDescriptor
                    )
                    try drainOutput(descriptor: outputDescriptor)
                    if let settled = store.authoritativeResult(id: requestID) {
                        store.removeOutput(id: requestID)
                        return .result(settled)
                    }
                    return try settleTimeout(
                        requestID: requestID,
                        note: approvalTimeoutNote
                    )
                }
                continue
            }
            if result < 0, errno != EINTR {
                throw SudoResultWaitError.event(errno)
            }
        }
    }

    private func settleTimeout(
        requestID: String,
        note: String
    ) throws -> SudoResultWaitOutcome {
        let disposition = try store.settlePendingTimeout(
            SudoResult(
                id: requestID,
                status: .failed,
                errorCode: .approvalTimedOut,
                note: note
            )
        )
        if let result = store.authoritativeResult(id: requestID) {
            store.removeOutput(id: requestID)
            if disposition == .pendingApproval,
               result.errorCode == .approvalTimedOut {
                return .timedOut(.pendingApproval)
            }
            return .result(result)
        }
        return .timedOut(disposition)
    }

    private func registerVnode(descriptor: Int32, queue: Int32) throws {
        var event = kevent(
            ident: UInt(descriptor),
            filter: Int16(EVFILT_VNODE),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR),
            fflags: UInt32(NOTE_WRITE | NOTE_EXTEND | NOTE_RENAME | NOTE_DELETE),
            data: 0,
            udata: nil
        )
        guard kevent(queue, &event, 1, nil, 0, nil) == 0 else {
            throw SudoResultWaitError.registration(errno)
        }
    }

    private func openOutputIfAvailable(
        requestID: String,
        queue: Int32,
        descriptor: inout Int32
    ) throws {
        guard descriptor < 0 else { return }
        let opened = Darwin.open(
            store.outputURL(id: requestID).path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        if opened < 0 {
            if errno == ENOENT { return }
            throw SudoResultWaitError.output(errno)
        }

        var status = stat()
        guard fstat(opened, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid() else {
            close(opened)
            throw SudoResultWaitError.unsafeOutput
        }
        do {
            try registerVnode(descriptor: opened, queue: queue)
            descriptor = opened
        } catch {
            close(opened)
            throw error
        }
    }

    private func drainOutput(descriptor: Int32) throws {
        guard descriptor >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            }
            if count > 0 {
                try io.writeStandardOutput(Data(bytes.prefix(count)))
            } else if count == 0 {
                return
            } else if errno != EINTR {
                throw SudoResultWaitError.output(errno)
            }
        }
    }
}

private enum SudoResultWaitError: Error {
    case queue(Int32)
    case directory(Int32)
    case timer(Int32)
    case registration(Int32)
    case event(Int32)
    case output(Int32)
    case unsafeOutput
}
