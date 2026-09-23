import Foundation
import Observation

/// Owns machine-create lifecycle, callback fencing, cancellation, and projection identity.
///
/// Register before starting I/O, then feed launcher events back with the returned
/// attempt. Apply returned effects only after each synchronous transition commits:
///
/// ```swift
/// let coordinator = CloudMachineCreateCoordinator(
///     output: CloudMachineCreateOutput(legacyCreatedFormat: "Created Cloud VM %@")
/// )
/// let attempt = coordinator.reserve(request)
/// // Start the process only after coordinator.projection contains its pending row.
/// ```
@MainActor
@Observable
public final class CloudMachineCreateCoordinator {
    /// An immutable snapshot shared by every panel, independent of rendering cadence.
    public private(set) var projection = CloudMachineCreateProjection()

    @ObservationIgnored private var attempts: [UUID: CloudMachineCreateAttempt] = [:]
    @ObservationIgnored private var carries: [UUID: String] = [:]
    @ObservationIgnored private var tombstones: [CloudMachineCreateAttempt: String] = [:]
    @ObservationIgnored private var cleanupIssued: Set<String> = []
    @ObservationIgnored private let output: CloudMachineCreateOutput
    @ObservationIgnored private let now: () -> Date

    /// Creates an isolated owner with injected parsing and time dependencies.
    /// - Parameters:
    ///   - output: Protocol parser configured by the app's localized CLI adapter.
    ///   - now: Clock used for pending row timestamps; tests may supply a fixed date.
    public init(output: CloudMachineCreateOutput, now: @escaping () -> Date = Date.init) {
        self.output = output
        self.now = now
    }

    /// Inserts a pending row synchronously, before any launcher or authentication work.
    /// - Parameter request: Immutable request reused for every retry.
    /// - Returns: The fence every callback from this attempt must carry.
    public func reserve(_ request: CloudMachineCreateRequest) -> CloudMachineCreateAttempt {
        let id = UUID()
        let attempt = CloudMachineCreateAttempt(operationID: id, canAllocateMachine: !request.isBaseSetup)
        projection.operations.append(CloudMachineCreateOperation(id: id, request: request, startedAt: now()))
        attempts[id] = attempt
        return attempt
    }

    /// Checks whether a callback still belongs to the active running attempt.
    /// - Parameter attempt: Fence captured before the process started.
    /// - Returns: False after completion, cancellation, retry, or account teardown.
    public func isActive(_ attempt: CloudMachineCreateAttempt) -> Bool {
        attempts[attempt.operationID] == attempt
    }

    /// Reuses a failed operation's request and identity with a fresh callback fence.
    /// - Parameter id: The failed logical operation.
    /// - Returns: A new attempt, or nil for a running, committed, or dismissed create.
    public func retry(_ id: UUID) -> CloudMachineCreateAttempt? {
        guard let index = projection.operations.firstIndex(where: { $0.id == id }),
              case .failed = projection.operations[index].phase else { return nil }
        let attempt = CloudMachineCreateAttempt(operationID: id, canAllocateMachine: !projection.operations[index].request.isBaseSetup && projection.operations[index].createdMachineID == nil)
        projection.operations[index].phase = .running
        attempts[id] = attempt
        carries[id] = nil
        return attempt
    }

    /// Rolls back a refused first launch or retains a refused retry as an inline failure.
    /// - Parameters:
    ///   - attempt: The launcher invocation that refused to start.
    ///   - retryFailure: A safe localized error for a retry, or nil for an initial launch.
    /// - Returns: Effects after the failed invocation is fenced out.
    public func refuse(_ attempt: CloudMachineCreateAttempt, retryFailure: String? = nil) -> CloudMachineCreateTransition {
        tombstones[attempt] = nil
        guard isActive(attempt), let index = projection.operations.firstIndex(where: { $0.id == attempt.operationID }) else { return .init() }
        attempts[attempt.operationID] = nil
        carries[attempt.operationID] = nil
        let refusedOperation = projection.operations[index]
        if let retryFailure {
            projection.operations[index].phase = .failed(output: retryFailure)
        } else {
            projection.operations.remove(at: index)
        }
        return CloudMachineCreateTransition(changed: true, closedOperations: retryFailure == nil ? [refusedOperation] : [])
    }

    /// Consumes process output, including late receipts from a cancelled invocation.
    /// - Parameters:
    ///   - chunk: The next ordered chunk from this process.
    ///   - attempt: The original callback fence.
    /// - Returns: Deduplicated cleanup or presentation effects.
    public func receive(_ chunk: String, from attempt: CloudMachineCreateAttempt) -> CloudMachineCreateTransition {
        var transition = CloudMachineCreateTransition()
        if var carry = tombstones[attempt] {
            let id = output.consume(chunk, carry: &carry)
            tombstones[attempt] = carry
            if let id { appendCleanup(id, to: &transition) }
            return transition
        }
        guard isActive(attempt), let index = projection.operations.firstIndex(where: { $0.id == attempt.operationID }) else { return transition }
        var carry = carries[attempt.operationID, default: ""]
        let id = output.consume(chunk, carry: &carry)
        carries[attempt.operationID] = carry
        if let id, projection.operations[index].createdMachineID == nil {
            projection.operations[index].createdMachineID = id
            adopt(projection.operations[index])
            transition.changed = true
        }
        return transition
    }

    /// Commits one current process result and ignores obsolete completions.
    /// - Parameters:
    ///   - completion: Receipt and already-redacted failure output from the launcher.
    ///   - attempt: The invocation that produced this result.
    /// - Returns: Effects to execute after the authoritative state has changed.
    public func finish(_ completion: CloudMachineCreateCompletion, from attempt: CloudMachineCreateAttempt) -> CloudMachineCreateTransition {
        var transition = CloudMachineCreateTransition()
        if let carry = tombstones.removeValue(forKey: attempt) {
            if let id = completion.machineID ?? output.machineID(in: carry + completion.output) {
                appendCleanup(id, to: &transition)
            }
            return transition
        }
        guard isActive(attempt), let index = projection.operations.firstIndex(where: { $0.id == attempt.operationID }) else { return transition }
        var operation = projection.operations[index]
        operation.createdMachineID = completion.machineID ?? operation.createdMachineID ?? output.machineID(in: completion.output)
        projection.operations[index] = operation
        adopt(operation)
        attempts[operation.id] = nil
        carries[operation.id] = nil
        transition.changed = true
        if completion.wasCancelled {
            projection.operations.remove(at: index)
            transition.closedOperations = [operation]
            if attempt.canAllocateMachine, let id = operation.createdMachineID { appendCleanup(id, to: &transition) }
            return transition
        }
        let outcome: CloudMachineCreateTransition.Outcome
        if completion.succeeded {
            outcome = .created(machineID: operation.createdMachineID, workspaceID: completion.workspaceID)
            if !operation.request.isBaseSetup, operation.request.retainsPendingProjection, let id = operation.createdMachineID {
                projection.operations[index].phase = .reconciling(machineID: id)
            } else {
                projection.operations.remove(at: index)
            }
        } else if !operation.request.isBaseSetup, let id = operation.createdMachineID {
            outcome = .createdButOpenFailed(machineID: id, output: completion.failureOutput)
            if operation.request.retainsPendingProjection {
                // Keep the inline failure. The retained receipt makes retry an open, never a create.
                projection.operations[index].phase = .failed(output: completion.failureOutput)
            } else {
                projection.operations.remove(at: index)
            }
        } else {
            outcome = .failed(output: completion.failureOutput)
            projection.operations[index].phase = .failed(output: completion.failureOutput)
        }
        transition.finished = .init(operation: operation, outcome: outcome)
        return transition
    }

    /// Retires acknowledged pending rows while retaining their identities for all panels.
    /// - Parameter machineIDs: Exact provider IDs from either fleet or catalog.
    /// - Returns: Whether the pending collection changed.
    @discardableResult
    public func reconcile(machineIDs: Set<String>) -> Bool {
        let count = projection.operations.count
        projection.operations.removeAll {
            if case .reconciling(let id) = $0.phase { return machineIDs.contains(id) }
            return false
        }
        return count != projection.operations.count
    }

    /// Cancels a running create, retaining a receipt tombstone before process termination.
    /// - Parameter id: The operation the user explicitly cancelled.
    /// - Returns: Process, cleanup, and presentation effects, or an empty transition.
    public func cancel(_ id: UUID) -> CloudMachineCreateTransition {
        remove(where: { $0.id == id && $0.phase == .running }, closePresentations: true)
    }

    /// Dismisses a failed create without re-running its command.
    /// - Parameter id: The inline failure the user dismissed.
    /// - Returns: Presentation cleanup effects, or an empty transition.
    public func dismiss(_ id: UUID) -> CloudMachineCreateTransition {
        remove(where: {
            guard $0.id == id, case .failed = $0.phase else { return false }
            return true
        }, closePresentations: true)
    }

    /// Cancels a set of closing workspaces in one pass without recursively closing them.
    /// - Parameter workspaceIDs: Workspaces whose teardown is already owned by the caller.
    /// - Returns: Cancellation and VM cleanup effects with no presentation-close callbacks.
    public func cancelPresentations(_ workspaceIDs: Set<UUID>) -> CloudMachineCreateTransition {
        remove(where: { $0.request.presentationWorkspaceID.map(workspaceIDs.contains) ?? false }, closePresentations: false)
    }

    /// Fences an account transition and clears account-specific projection aliases.
    /// - Parameter cleanupCreatedMachines: Whether the departing account permits cleanup.
    /// - Returns: Teardown effects; old callbacks may only produce cleanup, never UI state.
    public func endAccount(cleanupCreatedMachines: Bool = true) -> CloudMachineCreateTransition {
        let hadAliases = !projection.adoptedOperationIDs.isEmpty
        var transition = remove(where: { _ in true }, closePresentations: true, cleanup: cleanupCreatedMachines)
        projection.adoptedOperationIDs.removeAll()
        transition.changed = transition.changed || hadAliases
        return transition
    }

    /// Keeps aliases for the entire account session, never for just one render turn.
    private func adopt(_ operation: CloudMachineCreateOperation) {
        guard !operation.request.isBaseSetup, let id = operation.createdMachineID else { return }
        if projection.adoptedOperationIDs[id] == nil { projection.adoptedOperationIDs[id] = operation.id }
    }

    /// Partitions once, then installs all tombstones before any adapter can reenter.
    private func remove(
        where matches: (CloudMachineCreateOperation) -> Bool,
        closePresentations: Bool,
        cleanup: Bool = true
    ) -> CloudMachineCreateTransition {
        var removed: [CloudMachineCreateOperation] = []
        projection.operations.removeAll { operation in
            guard matches(operation) else { return false }
            removed.append(operation)
            return true
        }
        var transition = CloudMachineCreateTransition(changed: !removed.isEmpty)
        for operation in removed {
            let attempt = attempts.removeValue(forKey: operation.id)
            let carry = carries.removeValue(forKey: operation.id) ?? ""
            if let attempt {
                transition.cancelOperationIDs.append(operation.id)
                if cleanup && attempt.canAllocateMachine {
                    // Retain until termination, rather than evicting still-live cancellation receipts.
                    tombstones[attempt] = carry
                    if let id = operation.createdMachineID { appendCleanup(id, to: &transition) }
                }
            }
            if closePresentations { transition.closedOperations.append(operation) }
        }
        return transition
    }

    /// Issues one destruction request even when progress and completion repeat a receipt.
    private func appendCleanup(_ id: String, to transition: inout CloudMachineCreateTransition) {
        guard cleanupIssued.insert(id).inserted else { return }
        transition.cleanupMachineIDs.append(id)
    }
}
