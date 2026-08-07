internal import Foundation
internal import os

/// Admits native surface borrows before suspension and orders teardown after them.
///
/// Entries use the terminal's unique runtime-lifecycle identity rather than a
/// raw pointer address, which an allocator may reuse immediately after free.
final class TerminalSurfaceRuntimeNativeAccessGate: Sendable {
    /// A one-shot borrow whose lifetime prevents teardown of its native surface.
    final class Borrow: Sendable {
        private struct State {
            var gate: TerminalSurfaceRuntimeNativeAccessGate?
        }

        private let runtimeLifecycleId: UUID
        // Synchronous cancellation/deinit must release exactly once; this is a
        // bounded compare-and-set, not ongoing domain state.
        private let state: OSAllocatedUnfairLock<State>

        fileprivate init(
            gate: TerminalSurfaceRuntimeNativeAccessGate,
            runtimeLifecycleId: UUID
        ) {
            self.runtimeLifecycleId = runtimeLifecycleId
            state = OSAllocatedUnfairLock(initialState: State(gate: gate))
        }

        func release() {
            let gate = state.withLock { state in
                defer { state.gate = nil }
                return state.gate
            }
            gate?.releaseBorrow(runtimeLifecycleId: runtimeLifecycleId)
        }

        deinit {
            release()
        }
    }

    private enum Phase {
        case acceptingBorrows
        case teardownPending(@Sendable () -> Void)
        case tearingDown
    }

    private struct Entry {
        var borrowCount = 0
        var phase = Phase.acceptingBorrows
    }

    // Borrow admission and synchronous deinit teardown cannot await an actor.
    // The lock guards only short, nonblocking entry transitions; callbacks run
    // after unlock. Idle borrow entries leave on release, and teardown entries
    // leave immediately after the corresponding native free returns.
    private let entries = OSAllocatedUnfairLock(initialState: [UUID: Entry]())

    func acquireBorrow(for runtimeLifecycleId: UUID) -> Borrow? {
        let acquired = entries.withLock { entries in
            var entry = entries[runtimeLifecycleId] ?? Entry()
            guard case .acceptingBorrows = entry.phase else {
                return false
            }
            entry.borrowCount += 1
            entries[runtimeLifecycleId] = entry
            return true
        }
        guard acquired else { return nil }
        return Borrow(gate: self, runtimeLifecycleId: runtimeLifecycleId)
    }

    func requestTeardown(
        for runtimeLifecycleId: UUID,
        start: @escaping @Sendable () -> Void
    ) {
        let ready = entries.withLock { entries -> (@Sendable () -> Void)? in
            var entry = entries[runtimeLifecycleId] ?? Entry()
            guard case .acceptingBorrows = entry.phase else {
                return nil
            }
            guard entry.borrowCount > 0 else {
                entry.phase = .tearingDown
                entries[runtimeLifecycleId] = entry
                return start
            }
            entry.phase = .teardownPending(start)
            entries[runtimeLifecycleId] = entry
            return nil
        }
        ready?()
    }

    func finishTeardown(for runtimeLifecycleId: UUID) {
        entries.withLock { entries in
            guard let entry = entries[runtimeLifecycleId],
                  case .tearingDown = entry.phase,
                  entry.borrowCount == 0 else {
                return
            }
            entries.removeValue(forKey: runtimeLifecycleId)
        }
    }

    private func releaseBorrow(runtimeLifecycleId: UUID) {
        let ready = entries.withLock { entries -> (@Sendable () -> Void)? in
            guard var entry = entries[runtimeLifecycleId],
                  entry.borrowCount > 0 else {
                return nil
            }
            entry.borrowCount -= 1
            guard entry.borrowCount == 0 else {
                entries[runtimeLifecycleId] = entry
                return nil
            }
            switch entry.phase {
            case .acceptingBorrows:
                entries.removeValue(forKey: runtimeLifecycleId)
                return nil
            case .teardownPending(let pendingTeardown):
                entry.phase = .tearingDown
                entries[runtimeLifecycleId] = entry
                return pendingTeardown
            case .tearingDown:
                entries[runtimeLifecycleId] = entry
                return nil
            }
        }
        ready?()
    }
}
