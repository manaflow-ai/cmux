internal import GhosttyKit
internal import os

/// Admits native surface borrows before suspension and orders teardown after them.
///
/// `@unchecked Sendable` is safe because both the per-surface entries and each
/// borrow's one-shot release state are protected by their dedicated locks.
/// User callbacks always run after the entry lock is released.
final class TerminalSurfaceRuntimeNativeAccessGate: @unchecked Sendable {
    /// A one-shot borrow whose lifetime prevents teardown of its native surface.
    ///
    /// `@unchecked Sendable` is safe because its only mutable state is accessed
    /// through its dedicated lock and the referenced gate is concurrency-safe.
    final class Borrow: @unchecked Sendable {
        private struct State {
            var gate: TerminalSurfaceRuntimeNativeAccessGate?
        }

        private let surfaceKey: UInt
        // Synchronous cancellation/deinit must release exactly once; this is a
        // bounded compare-and-set, not ongoing domain state.
        private let state: OSAllocatedUnfairLock<State>

        fileprivate init(
            gate: TerminalSurfaceRuntimeNativeAccessGate,
            surfaceKey: UInt
        ) {
            self.surfaceKey = surfaceKey
            state = OSAllocatedUnfairLock(initialState: State(gate: gate))
        }

        func release() {
            let gate = state.withLock { state in
                defer { state.gate = nil }
                return state.gate
            }
            gate?.releaseBorrow(surfaceKey: surfaceKey)
        }

        deinit {
            release()
        }
    }

    private struct Entry {
        var borrowCount = 0
        var teardownStarted = false
        var pendingTeardown: (@Sendable () -> Void)?
    }

    // Borrow admission and synchronous deinit teardown cannot await an actor.
    // The lock guards only bounded counters/flags; callbacks run after unlock.
    private let entries = OSAllocatedUnfairLock(initialState: [UInt: Entry]())

    func acquireBorrow(for surface: ghostty_surface_t) -> Borrow? {
        let surfaceKey = UInt(bitPattern: surface)
        let acquired = entries.withLock { entries in
            var entry = entries[surfaceKey] ?? Entry()
            guard !entry.teardownStarted,
                  entry.pendingTeardown == nil else {
                return false
            }
            entry.borrowCount += 1
            entries[surfaceKey] = entry
            return true
        }
        guard acquired else { return nil }
        return Borrow(gate: self, surfaceKey: surfaceKey)
    }

    func requestTeardown(
        for surface: ghostty_surface_t,
        start: @escaping @Sendable () -> Void
    ) {
        let surfaceKey = UInt(bitPattern: surface)
        let ready = entries.withLock { entries -> (@Sendable () -> Void)? in
            var entry = entries[surfaceKey] ?? Entry()
            guard !entry.teardownStarted,
                  entry.pendingTeardown == nil else {
                return nil
            }
            guard entry.borrowCount > 0 else {
                entry.teardownStarted = true
                entries[surfaceKey] = entry
                return start
            }
            entry.pendingTeardown = start
            entries[surfaceKey] = entry
            return nil
        }
        ready?()
    }

    func finishTeardown(for surface: ghostty_surface_t) {
        let surfaceKey = UInt(bitPattern: surface)
        entries.withLock { entries in
            guard let entry = entries[surfaceKey],
                  entry.teardownStarted,
                  entry.borrowCount == 0 else {
                return
            }
            entries.removeValue(forKey: surfaceKey)
        }
    }

    private func releaseBorrow(surfaceKey: UInt) {
        let ready = entries.withLock { entries -> (@Sendable () -> Void)? in
            guard var entry = entries[surfaceKey],
                  entry.borrowCount > 0 else {
                return nil
            }
            entry.borrowCount -= 1
            guard entry.borrowCount == 0,
                  let pendingTeardown = entry.pendingTeardown else {
                entries[surfaceKey] = entry
                return nil
            }
            entry.pendingTeardown = nil
            entry.teardownStarted = true
            entries[surfaceKey] = entry
            return pendingTeardown
        }
        ready?()
    }
}
