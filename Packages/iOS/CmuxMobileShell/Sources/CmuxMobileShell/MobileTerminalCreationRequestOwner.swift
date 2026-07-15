internal import CmuxMobileShellModel
internal import Foundation

/// Owns one remote terminal-create task and its hierarchy mutation reservation.
///
/// Transport cancellation is cooperative, so a request can remain suspended
/// after its connection is replaced. This owner consumes the request token and
/// completes the UI synchronously on cancellation without waiting for the task
/// to unwind. Reserved hierarchies stay fenced until an authoritative refresh.
@MainActor
final class MobileTerminalCreationRequestOwner {
    private typealias Outcome = Result<Void, MobileWorkspaceMutationFailure>

    private var task: Task<Void, Never>?
    private var taskID: UUID?
    private var claim: MobileTerminalCreationMutationClaim?
    private var cancellationOutcome: Outcome?
    private var outcomeCompletion: (@MainActor (Outcome) -> Void)?

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
        cancellationOutcome = nil
        outcomeCompletion = nil
        task = Task { @MainActor [weak self] in
            defer { self?.finish(id: id, gate: gate) }
            await operation()
        }
        return true
    }

    @discardableResult
    func startIfIdle(
        claim: MobileTerminalCreationMutationClaim,
        gate: MobileTerminalReorderGate,
        cancellationOutcome: Result<Void, MobileWorkspaceMutationFailure>,
        completion: @escaping @MainActor (Result<Void, MobileWorkspaceMutationFailure>) -> Void,
        operation: @escaping @MainActor () async -> Result<Void, MobileWorkspaceMutationFailure>
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
        self.cancellationOutcome = cancellationOutcome
        outcomeCompletion = completion
        task = Task { @MainActor [weak self] in
            let outcome = await operation()
            self?.complete(outcome, id: id, gate: gate)
        }
        return true
    }

    func cancel(gate: MobileTerminalReorderGate) {
        task?.cancel()
        guard let taskID else {
            task = nil
            return
        }
        if case let .reserved(reservation) = claim {
            gate.requireRefresh(workspaceID: reservation.workspaceID)
        }
        if let cancellationOutcome {
            complete(cancellationOutcome, id: taskID, gate: gate)
        } else {
            finish(id: taskID, gate: gate)
        }
    }

    private func finish(id: UUID, gate: MobileTerminalReorderGate) {
        guard taskID == id else { return }
        let finishedClaim = claim
        task = nil
        taskID = nil
        claim = nil
        cancellationOutcome = nil
        outcomeCompletion = nil
        if let finishedClaim, case let .reserved(reservation) = finishedClaim {
            gate.finish(reservation)
        }
    }

    private func complete(
        _ outcome: Outcome,
        id: UUID,
        gate: MobileTerminalReorderGate
    ) {
        guard taskID == id else { return }
        let completion = outcomeCompletion
        finish(id: id, gate: gate)
        completion?(outcome)
    }

    isolated deinit {
        task?.cancel()
    }
}
