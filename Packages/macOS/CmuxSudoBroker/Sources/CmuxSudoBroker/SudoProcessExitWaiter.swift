import Darwin
import Foundation

struct SudoProcessExitWaiter: Sendable {
    private let inspector: any SudoProcessInspecting

    init(inspector: any SudoProcessInspecting) {
        self.inspector = inspector
    }

    /// Waits for process-generation exit events until a kernel timer fires.
    ///
    /// This is the low-level process bridge: `EVFILT_PROC` and a one-shot
    /// `EVFILT_TIMER` provide event-driven completion without sleep-based polling.
    func survivors(
        among identities: [SudoProcessIdentity],
        after timeout: TimeInterval
    ) -> [SudoProcessIdentity] {
        var remaining = identities.filter(inspector.isRunning)
        guard !remaining.isEmpty, timeout > 0 else { return remaining }

        let queue = kqueue()
        guard queue >= 0 else { return remaining }
        defer { close(queue) }

        for identity in remaining {
            var processEvent = kevent(
                ident: UInt(identity.processIdentifier),
                filter: Int16(EVFILT_PROC),
                flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
                fflags: UInt32(NOTE_EXIT),
                data: 0,
                udata: nil
            )
            while kevent(queue, &processEvent, 1, nil, 0, nil) != 0, errno == EINTR {}
        }
        remaining = remaining.filter(inspector.isRunning)
        guard !remaining.isEmpty else { return [] }

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
        guard kevent(queue, &timerEvent, 1, nil, 0, nil) == 0 else { return remaining }

        while !remaining.isEmpty {
            var triggeredEvent = kevent()
            let result = kevent(queue, nil, 0, &triggeredEvent, 1, nil)
            if result > 0 {
                remaining = remaining.filter(inspector.isRunning)
                if triggeredEvent.filter == Int16(EVFILT_TIMER),
                   triggeredEvent.ident == timerIdentifier {
                    return remaining
                }
            } else if result < 0, errno != EINTR {
                return remaining.filter(inspector.isRunning)
            }
        }
        return []
    }
}
