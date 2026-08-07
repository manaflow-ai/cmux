internal import CmuxFoundation

/// Orders native surface borrows before the teardown of one runtime generation.
///
/// The high state bit permanently closes borrow admission. Lower bits count
/// active borrows. A retained one-shot teardown action is published before the
/// close transition, so either the closer or the final borrower can claim and
/// run it synchronously without a task hop.
final class TerminalSurfaceRuntimeNativeAccessGate: Sendable {
    private static let teardownRequestedMask: UInt64 = 1 << 63
    private static let borrowCountMask = teardownRequestedMask - 1

    private let state = AtomicUInt64Value()
    private let pendingTeardownAction = AtomicRawPointerValue()

    /// Acquires a borrow unless teardown has already claimed this generation.
    func acquireBorrow() -> TerminalSurfaceRuntimeNativeAccessBorrow? {
        while true {
            let current = state.loadAcquire()
            guard current & Self.teardownRequestedMask == 0,
                  current != Self.borrowCountMask else {
                return nil
            }
            guard state.compareExchange(
                expected: current,
                desired: current + 1
            ) else {
                continue
            }
            return TerminalSurfaceRuntimeNativeAccessBorrow(gate: self)
        }
    }

    /// Closes admission and starts teardown after all admitted borrows finish.
    func requestTeardown(start: @escaping @Sendable () -> Void) {
        let retainedAction = Unmanaged.passRetained(
            TerminalSurfaceRuntimeTeardownAction(start: start)
        )
        let actionPointer = UnsafeRawPointer(retainedAction.toOpaque())
        guard pendingTeardownAction.compareExchange(
            expected: nil,
            desired: actionPointer
        ) else {
            retainedAction.release()
            return
        }

        while true {
            let current = state.loadAcquire()
            guard current & Self.teardownRequestedMask == 0 else {
                discardPendingAction(actionPointer: actionPointer)
                return
            }
            let closed = current | Self.teardownRequestedMask
            guard state.compareExchange(expected: current, desired: closed) else {
                continue
            }
            if closed & Self.borrowCountMask == 0 {
                runPendingTeardown()
            }
            return
        }
    }

    /// Releases one admitted borrow and starts any newly-unblocked teardown.
    fileprivate func releaseBorrow() {
        while true {
            let current = state.loadAcquire()
            let borrowCount = current & Self.borrowCountMask
            guard borrowCount > 0 else { return }
            let released = current - 1
            guard state.compareExchange(expected: current, desired: released) else {
                continue
            }
            if released == Self.teardownRequestedMask {
                runPendingTeardown()
            }
            return
        }
    }

    private func runPendingTeardown() {
        while true {
            guard let actionPointer = pendingTeardownAction.loadAcquire() else {
                return
            }
            guard pendingTeardownAction.compareExchange(
                expected: actionPointer,
                desired: nil
            ) else {
                continue
            }
            takeRetainedAction(actionPointer: actionPointer).run()
            return
        }
    }

    private func discardPendingAction(actionPointer: UnsafeRawPointer) {
        guard pendingTeardownAction.compareExchange(
            expected: actionPointer,
            desired: nil
        ) else {
            return
        }
        _ = takeRetainedAction(actionPointer: actionPointer)
    }

    private func takeRetainedAction(
        actionPointer: UnsafeRawPointer
    ) -> TerminalSurfaceRuntimeTeardownAction {
        return Unmanaged<TerminalSurfaceRuntimeTeardownAction>
            .fromOpaque(actionPointer)
            .takeRetainedValue()
    }
}
