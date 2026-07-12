internal import CmuxMobileShellModel
internal import Foundation

/// Owns one remote terminal-create task and its hierarchy mutation reservation.
///
/// Transport cancellation is cooperative, so a request can remain suspended
/// after its connection is replaced. This owner releases the UI reservation
/// synchronously on cancellation without waiting for the task to unwind.
@MainActor
final class MobileTerminalCreationRequestOwner {
    private var task: Task<Void, Never>?
    private var taskID: UUID?
    private var claim: MobileTerminalCreationMutationClaim?

    var isActive: Bool { taskID != nil }

    @discardableResult
    func startIfIdle(
        claim: MobileTerminalCreationMutationClaim,
        gate: MobileTerminalReorderGate,
        operation: @escaping @MainActor () async -> Void
    ) -> Bool {
        guard taskID == nil else {
            if case let .reserved(reservation) = claim {
                gate.finish(reservation)
            }
            return false
        }
        let id = UUID()
        taskID = id
        self.claim = claim
        task = Task { @MainActor [weak self] in
            defer { self?.finish(id: id, gate: gate) }
            await operation()
        }
        return true
    }

    func cancel(gate: MobileTerminalReorderGate) {
        task?.cancel()
        guard let taskID else {
            task = nil
            return
        }
        finish(id: taskID, gate: gate)
    }

    private func finish(id: UUID, gate: MobileTerminalReorderGate) {
        guard taskID == id else { return }
        let finishedClaim = claim
        task = nil
        taskID = nil
        claim = nil
        if let finishedClaim, case let .reserved(reservation) = finishedClaim {
            gate.finish(reservation)
        }
    }

    isolated deinit {
        task?.cancel()
    }
}
