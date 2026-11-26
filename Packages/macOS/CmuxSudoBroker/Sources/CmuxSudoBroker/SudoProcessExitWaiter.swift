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
        let observed = identities.filter(inspector.isRunning)
        var identityByProcessIdentifier = Dictionary(
            observed.map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { existing, replacement in
                self.inspector.isRunning(replacement) ? replacement : existing
            }
        )
        let initial = Array(identityByProcessIdentifier.values)
        var remaining = Set(initial)
        guard !remaining.isEmpty, timeout > 0 else { return initial }

        let queue = kqueue()
        guard queue >= 0 else { return initial }
        defer { close(queue) }

        for identity in initial {
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
        for identity in initial where !inspector.isRunning(identity) {
            remaining.remove(identity)
            identityByProcessIdentifier.removeValue(forKey: identity.processIdentifier)
        }
        guard !remaining.isEmpty else { return [] }

        let timerIdentifier = UInt.max
        let milliseconds = SudoKeventTimeout(seconds: timeout).milliseconds
        var timerEvent = kevent(
            ident: timerIdentifier,
            filter: Int16(EVFILT_TIMER),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: 0,
            data: milliseconds,
            udata: nil
        )
        guard kevent(queue, &timerEvent, 1, nil, 0, nil) == 0 else {
            return identityByProcessIdentifier.values.filter {
                remaining.contains($0) && inspector.isRunning($0)
            }
        }

        while !remaining.isEmpty {
            var triggeredEvent = kevent()
            let result = kevent(queue, nil, 0, &triggeredEvent, 1, nil)
            if result > 0 {
                if triggeredEvent.filter == Int16(EVFILT_TIMER),
                   triggeredEvent.ident == timerIdentifier {
                    return identityByProcessIdentifier.values.filter {
                        remaining.contains($0) && inspector.isRunning($0)
                    }
                }
                if triggeredEvent.filter == Int16(EVFILT_PROC),
                   let processIdentifier = Int32(exactly: triggeredEvent.ident),
                   let identity = identityByProcessIdentifier[processIdentifier],
                   !inspector.isRunning(identity) {
                    remaining.remove(identity)
                    identityByProcessIdentifier.removeValue(forKey: processIdentifier)
                }
            } else if result < 0, errno != EINTR {
                return identityByProcessIdentifier.values.filter {
                    remaining.contains($0) && inspector.isRunning($0)
                }
            }
        }
        return []
    }
}
