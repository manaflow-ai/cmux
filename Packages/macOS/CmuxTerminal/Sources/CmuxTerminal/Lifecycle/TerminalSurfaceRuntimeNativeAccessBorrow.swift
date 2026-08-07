internal import CmuxFoundation

/// A one-shot borrow that keeps one native runtime generation accessible.
final class TerminalSurfaceRuntimeNativeAccessBorrow: Sendable {
    private let gate: TerminalSurfaceRuntimeNativeAccessGate
    private let isActive = AtomicBooleanGate(true)

    init(gate: TerminalSurfaceRuntimeNativeAccessGate) {
        self.gate = gate
    }

    func release() {
        guard isActive.compareExchange(expected: true, desired: false) else {
            return
        }
        gate.releaseBorrow()
    }

    deinit {
        release()
    }
}
