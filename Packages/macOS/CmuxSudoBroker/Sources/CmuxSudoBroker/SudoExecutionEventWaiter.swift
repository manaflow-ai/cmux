import Darwin
import Foundation

/// Waits for execution exit, password fallback, or the independent deadline.
struct SudoExecutionEventWaiter: Sendable {
    private let inspector: any SudoProcessInspecting
    private let outputDetector: SudoAuthenticationOutputDetector
    private let exitWaiter: SudoProcessExitWaiter

    init(
        inspector: any SudoProcessInspecting,
        outputDetector: SudoAuthenticationOutputDetector
    ) {
        self.inspector = inspector
        self.outputDetector = outputDetector
        exitWaiter = SudoProcessExitWaiter(inspector: inspector)
    }

    /// Uses kernel process, vnode, and timer events without polling or sleeps.
    func wait(
        for process: SudoSpawnedProcess,
        after timeout: TimeInterval
    ) -> SudoExecutionWaitDisposition {
        guard inspector.isRunning(process.identity) else { return .exited }
        guard !outputDetector.indicatesPasswordPrompt(at: process.outputURL) else {
            return .authenticationFailed
        }
        guard timeout > 0 else { return .timedOut }

        let outputDescriptor = Darwin.open(
            process.outputURL.path,
            O_EVTONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard outputDescriptor >= 0 else {
            return fallback(for: process, after: timeout)
        }
        defer { Darwin.close(outputDescriptor) }

        let queue = kqueue()
        guard queue >= 0 else {
            return fallback(for: process, after: timeout)
        }
        defer { Darwin.close(queue) }

        var processEvent = kevent(
            ident: UInt(process.identity.processIdentifier),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT),
            data: 0,
            udata: nil
        )
        guard Self.register(&processEvent, on: queue) else {
            return fallback(for: process, after: timeout)
        }

        var outputEvent = kevent(
            ident: UInt(outputDescriptor),
            filter: Int16(EVFILT_VNODE),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR),
            fflags: UInt32(NOTE_WRITE | NOTE_EXTEND),
            data: 0,
            udata: nil
        )
        guard Self.register(&outputEvent, on: queue) else {
            return fallback(for: process, after: timeout)
        }

        guard inspector.isRunning(process.identity) else { return .exited }
        guard !outputDetector.indicatesPasswordPrompt(at: process.outputURL) else {
            return .authenticationFailed
        }

        let timerIdentifier = UInt.max
        let milliseconds = max(1, min(Int.max, Int(ceil(timeout * 1_000))))
        var timerEvent = kevent(
            ident: timerIdentifier,
            filter: Int16(EVFILT_TIMER),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: 0,
            data: milliseconds,
            udata: nil
        )
        guard Self.register(&timerEvent, on: queue) else {
            return fallback(for: process, after: timeout)
        }

        while inspector.isRunning(process.identity) {
            var triggeredEvent = kevent()
            let result = Self.receive(&triggeredEvent, from: queue)
            guard result > 0 else {
                return fallback(for: process, after: timeout)
            }
            if triggeredEvent.filter == Int16(EVFILT_VNODE),
               triggeredEvent.ident == UInt(outputDescriptor),
               outputDetector.indicatesPasswordPrompt(at: process.outputURL) {
                return .authenticationFailed
            }
            if triggeredEvent.filter == Int16(EVFILT_TIMER),
               triggeredEvent.ident == timerIdentifier {
                return inspector.isRunning(process.identity) ? .timedOut : .exited
            }
        }
        return .exited
    }

    private func fallback(
        for process: SudoSpawnedProcess,
        after timeout: TimeInterval
    ) -> SudoExecutionWaitDisposition {
        if outputDetector.indicatesPasswordPrompt(at: process.outputURL) {
            return .authenticationFailed
        }
        let survivors = exitWaiter.survivors(
            among: [process.identity],
            after: timeout
        )
        if outputDetector.indicatesPasswordPrompt(at: process.outputURL) {
            return .authenticationFailed
        }
        return survivors.isEmpty ? .exited : .timedOut
    }

    private static func register(_ event: inout kevent, on queue: Int32) -> Bool {
        var result: Int32
        repeat {
            result = kevent(queue, &event, 1, nil, 0, nil)
        } while result < 0 && errno == EINTR
        return result == 0
    }

    private static func receive(_ event: inout kevent, from queue: Int32) -> Int32 {
        var result: Int32
        repeat {
            result = kevent(queue, nil, 0, &event, 1, nil)
        } while result < 0 && errno == EINTR
        return result
    }
}
