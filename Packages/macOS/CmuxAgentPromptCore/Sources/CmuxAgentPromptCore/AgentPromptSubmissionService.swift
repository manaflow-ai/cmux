public import CmuxTerminalCore
public import Foundation

/// Owns the bounded workspace FIFO for addressed agent-prompt delivery.
///
/// The service owns delivery ordering only. Prompt identity, hook matching,
/// source attribution, and human-input snapshots are owned by the target
/// terminal's ``TerminalPromptInputLedger``. The delivery closure receives the
/// service's stable message ID so the terminal can record that ID in the same
/// admission transition as the compound write.
@MainActor
public final class AgentPromptSubmissionService {
    /// Maximum UTF-8 payload accepted for one addressed prompt.
    public nonisolated static let maximumPromptBytes = 1_048_576

    /// Main-actor operation that attempts one complete prompt transaction.
    public typealias Delivery =
        @MainActor @Sendable (_ messageID: UUID) -> AgentPromptSubmissionResult

    /// Backward-compatible nested name for a prompt-delivery receipt.
    public typealias Receipt = AgentPromptSubmissionReceipt

    private let maximumPendingRequests: Int
    private let maximumPendingBytes = 8 * 1_048_576
    private let now: @Sendable () -> Date
    private var pendingByWorkspace: [UUID: [AgentPromptSubmissionPendingRequest]] = [:]
    private var pendingBytes = 0

    /// One accepted request at a time is the workspace FIFO barrier.
    ///
    /// This map contains no prompt text, signature, source, or human snapshot;
    /// those values live in the target surface ledger. Keeping only the
    /// ordering barrier here prevents two mutable owners from drifting.
    private var inFlightByWorkspace: [UUID: AgentPromptSubmissionInFlightRequest] = [:]

    /// How long an accepted prompt may block its workspace FIFO without a
    /// matching hook confirmation.
    public let confirmationTimeout: TimeInterval

    /// Creates a bounded addressed-prompt admission service.
    ///
    /// - Parameters:
    ///   - maximumPendingRequests: Maximum number of queued requests across
    ///     all workspaces.
    ///   - confirmationTimeout: Maximum age of an unconfirmed delivery before
    ///     its workspace may advance. The terminal ledger retains the prompt
    ///     record so a late hook can still report its message ID.
    ///   - now: Clock seam used to timestamp accepted requests.
    public init(
        maximumPendingRequests: Int = 256,
        confirmationTimeout: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = { Date.now }
    ) {
        self.maximumPendingRequests = max(1, maximumPendingRequests)
        self.confirmationTimeout = max(0, confirmationTimeout)
        self.now = now
    }

    /// Clears an expired workspace ordering barrier.
    ///
    /// Prompt attribution remains in the target surface ledger. A later hook
    /// can therefore still recover the original message ID after this method
    /// allows a queued request to proceed.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace whose barrier should be checked.
    ///   - now: Optional test instant; the injected clock is used by default.
    /// - Returns: The expired message ID, when a barrier was cleared.
    @discardableResult
    public func expireStaleInFlight(
        workspaceID: UUID,
        now: Date? = nil
    ) -> UUID? {
        guard let inFlight = inFlightByWorkspace[workspaceID],
              (now ?? self.now()).timeIntervalSince(inFlight.acceptedAt)
                >= confirmationTimeout else {
            return nil
        }
        inFlightByWorkspace.removeValue(forKey: workspaceID)
        return inFlight.messageID
    }

    /// Admits one request and returns its stable message ID immediately.
    ///
    /// The delivery closure runs synchronously on the main actor for the first
    /// request in an idle workspace. Busy or temporarily unavailable outcomes
    /// are retained as one untouched queued transaction.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace used as the serialization boundary.
    ///   - requestedSurfaceID: Optional surface selected by the caller.
    ///   - text: Complete prompt body.
    ///   - delivery: Main-actor compound delivery operation.
    /// - Returns: The request's stable ID and immediate result.
    public func submit(
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        text: String,
        delivery: @escaping Delivery
    ) -> Receipt {
        let messageID = UUID()
        guard text.utf8.count <= Self.maximumPromptBytes else {
            return Receipt(
                messageID: messageID,
                result: .promptTooLarge(
                    workspaceID: workspaceID,
                    surfaceID: requestedSurfaceID,
                    maximumBytes: Self.maximumPromptBytes
                )
            )
        }

        let request = AgentPromptSubmissionPendingRequest(
            messageID: messageID,
            workspaceID: workspaceID,
            surfaceID: requestedSurfaceID,
            text: text,
            delivery: delivery
        )
        expireStaleInFlight(workspaceID: workspaceID)

        if pendingCount >= maximumPendingRequests {
            return Receipt(
                messageID: messageID,
                result: .submissionQueueFull(
                    workspaceID: workspaceID,
                    surfaceID: requestedSurfaceID
                )
            )
        }

        if pendingByWorkspace[workspaceID]?.isEmpty == false {
            guard enqueue(request) else {
                return Receipt(
                    messageID: messageID,
                    result: .submissionQueueFull(
                        workspaceID: workspaceID,
                        surfaceID: requestedSurfaceID
                    )
                )
            }
            return Receipt(
                messageID: messageID,
                result: .queued(
                    workspaceID: workspaceID,
                    surfaceID:
                        requestedSurfaceID
                        ?? pendingByWorkspace[workspaceID]?.first?.surfaceID,
                    reason: "workspace_fifo"
                )
            )
        }

        if let inFlight = inFlightByWorkspace[workspaceID] {
            guard enqueue(request, surfaceID: inFlight.surfaceID) else {
                return Receipt(
                    messageID: messageID,
                    result: .submissionQueueFull(
                        workspaceID: workspaceID,
                        surfaceID: inFlight.surfaceID
                    )
                )
            }
            return Receipt(
                messageID: messageID,
                result: .queued(
                    workspaceID: workspaceID,
                    surfaceID: inFlight.surfaceID,
                    reason: "prior_prompt_in_flight"
                )
            )
        }

        let result = delivery(messageID)
        switch result {
        case .rejectedComposerBusy(let resolvedWorkspaceID, let surfaceID):
            guard enqueue(request, surfaceID: surfaceID) else {
                return Receipt(
                    messageID: messageID,
                    result: .submissionQueueFull(
                        workspaceID: workspaceID,
                        surfaceID: surfaceID
                    )
                )
            }
            return Receipt(
                messageID: messageID,
                result: .queued(
                    workspaceID: resolvedWorkspaceID,
                    surfaceID: surfaceID,
                    reason: "human_composer_busy"
                )
            )
        case .agentBusy(let resolvedWorkspaceID, let surfaceID):
            guard enqueue(request, surfaceID: surfaceID) else {
                return Receipt(
                    messageID: messageID,
                    result: .submissionQueueFull(
                        workspaceID: workspaceID,
                        surfaceID: surfaceID
                    )
                )
            }
            return Receipt(
                messageID: messageID,
                result: .queued(
                    workspaceID: resolvedWorkspaceID,
                    surfaceID: surfaceID,
                    reason: "agent_turn_active"
                )
            )
        case .agentScopeUnavailable(let resolvedWorkspaceID, let surfaceID):
            guard enqueue(request, surfaceID: surfaceID) else {
                return Receipt(
                    messageID: messageID,
                    result: .submissionQueueFull(
                        workspaceID: workspaceID,
                        surfaceID: surfaceID
                    )
                )
            }
            return Receipt(
                messageID: messageID,
                result: .queued(
                    workspaceID: resolvedWorkspaceID,
                    surfaceID: surfaceID,
                    reason: "agent_not_ready"
                )
            )
        case .submitted(let resolvedWorkspaceID, let surfaceID, let queued):
            if queued {
                guard enqueue(request, surfaceID: surfaceID) else {
                    return Receipt(
                        messageID: messageID,
                        result: .submissionQueueFull(
                            workspaceID: workspaceID,
                            surfaceID: surfaceID
                        )
                    )
                }
                return Receipt(
                    messageID: messageID,
                    result: .queued(
                        workspaceID: resolvedWorkspaceID,
                        surfaceID: surfaceID,
                        reason: "runtime_starting"
                    )
                )
            }
            beginInFlight(
                messageID: messageID,
                workspaceID: workspaceID,
                surfaceID: surfaceID
            )
            return Receipt(
                messageID: messageID,
                result: .submitted(
                    workspaceID: resolvedWorkspaceID,
                    surfaceID: surfaceID,
                    queued: false
                )
            )
        default:
            return Receipt(messageID: messageID, result: result)
        }
    }

    /// Retries requests retained for a workspace.
    ///
    /// - Parameter workspaceID: Workspace whose FIFO should be retried.
    /// - Returns: Receipts for requests that reached a definitive outcome.
    @discardableResult
    public func drain(workspaceID: UUID) -> [Receipt] {
        expireStaleInFlight(workspaceID: workspaceID)
        guard inFlightByWorkspace[workspaceID] == nil else { return [] }
        guard var pending = pendingByWorkspace[workspaceID], !pending.isEmpty else {
            pendingByWorkspace.removeValue(forKey: workspaceID)
            return []
        }

        var completed: [Receipt] = []
        while let first = pending.first {
            let result = first.delivery(first.messageID)
            switch result {
            case .rejectedComposerBusy,
                 .agentBusy,
                 .agentScopeUnavailable,
                 .agentNotFound,
                 .ambiguousAgent:
                // Target resolution can briefly lose an agent while a cold
                // or hibernated surface is rebinding. Retain the request;
                // explicit workspace/surface removal is the terminal cleanup
                // path and prevents a prompt from being lost on a wake race.
                pendingByWorkspace[workspaceID] = pending
                return completed
            case .submitted(let resolvedWorkspaceID, let surfaceID, let queued):
                if queued {
                    pendingByWorkspace[workspaceID] = pending
                    return completed
                }
                pending.removeFirst()
                pendingBytes = max(0, pendingBytes - first.text.utf8.count)
                beginInFlight(
                    messageID: first.messageID,
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                )
                completed.append(
                    Receipt(
                        messageID: first.messageID,
                        result: .submitted(
                            workspaceID: resolvedWorkspaceID,
                            surfaceID: surfaceID,
                            queued: false
                        )
                    )
                )
            default:
                // A permanently missing workspace or surface is terminal for
                // the retained request; do not retry it forever.
                pending.removeFirst()
                pendingBytes = max(0, pendingBytes - first.text.utf8.count)
                completed.append(
                    Receipt(messageID: first.messageID, result: result)
                )
            }
        }

        pendingByWorkspace.removeValue(forKey: workspaceID)
        return completed
    }

    /// Confirms the workspace ordering barrier for a ledger-owned prompt.
    ///
    /// The surface ledger performs message matching and supplies the ID. This
    /// method only releases the corresponding workspace FIFO barrier.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace owning the barrier.
    ///   - surfaceID: Surface that accepted the prompt.
    ///   - messageID: ID returned by the target surface ledger.
    /// - Returns: Whether the current barrier matched and was released.
    @discardableResult
    public func confirm(
        workspaceID: UUID,
        surfaceID: UUID,
        messageID: UUID
    ) -> Bool {
        guard let inFlight = inFlightByWorkspace[workspaceID],
              inFlight.surfaceID == surfaceID,
              inFlight.messageID == messageID else {
            return false
        }
        inFlightByWorkspace.removeValue(forKey: workspaceID)
        return true
    }

    /// Drops all queued and awaiting requests for a closed workspace.
    ///
    /// - Parameter workspaceID: Workspace being permanently removed.
    /// - Returns: Failure receipts for every removed request.
    @discardableResult
    public func remove(workspaceID: UUID) -> [Receipt] {
        let pending = pendingByWorkspace.removeValue(forKey: workspaceID) ?? []
        pendingBytes = max(
            0,
            pendingBytes - pending.reduce(0) { $0 + $1.text.utf8.count }
        )
        var receipts = pending.map { request in
            Receipt(
                messageID: request.messageID,
                result: .workspaceNotFound(workspaceID: workspaceID)
            )
        }
        if let inFlight = inFlightByWorkspace.removeValue(forKey: workspaceID) {
            receipts.append(
                Receipt(
                    messageID: inFlight.messageID,
                    result: .workspaceNotFound(workspaceID: workspaceID)
                )
            )
        }
        return receipts
    }

    /// Drops requests explicitly tied to a terminal surface being torn down.
    ///
    /// - Parameter surfaceID: Surface that is no longer targetable.
    /// - Returns: Failure receipts for removed requests.
    @discardableResult
    public func remove(surfaceID: UUID) -> [Receipt] {
        var receipts: [Receipt] = []
        for (workspaceID, pending) in Array(pendingByWorkspace) {
            let removed = pending.filter { $0.surfaceID == surfaceID }
            guard !removed.isEmpty else { continue }
            let remaining = pending.filter { $0.surfaceID != surfaceID }
            pendingBytes = max(
                0,
                pendingBytes - removed.reduce(0) { $0 + $1.text.utf8.count }
            )
            if remaining.isEmpty {
                pendingByWorkspace.removeValue(forKey: workspaceID)
            } else {
                pendingByWorkspace[workspaceID] = remaining
            }
            receipts.append(contentsOf: removed.map { request in
                Receipt(
                    messageID: request.messageID,
                    result: .surfaceNotFound(
                        workspaceID: workspaceID,
                        surfaceID: surfaceID
                    )
                )
            })
        }
        for (workspaceID, inFlight) in Array(inFlightByWorkspace)
            where inFlight.surfaceID == surfaceID {
            inFlightByWorkspace.removeValue(forKey: workspaceID)
            receipts.append(
                Receipt(
                    messageID: inFlight.messageID,
                    result: .surfaceNotFound(
                        workspaceID: workspaceID,
                        surfaceID: surfaceID
                    )
                )
            )
        }
        return receipts
    }

    /// Number of requests retained for later delivery.
    public var pendingCount: Int {
        pendingByWorkspace.values.reduce(0) { $0 + $1.count }
    }

    private func beginInFlight(
        messageID: UUID,
        workspaceID: UUID,
        surfaceID: UUID
    ) {
        inFlightByWorkspace[workspaceID] = AgentPromptSubmissionInFlightRequest(
            messageID: messageID,
            surfaceID: surfaceID,
            acceptedAt: now()
        )
    }

    private func enqueue(
        _ request: AgentPromptSubmissionPendingRequest,
        surfaceID: UUID? = nil
    ) -> Bool {
        let requestBytes = request.text.utf8.count
        guard pendingCount < maximumPendingRequests,
              pendingBytes + requestBytes <= maximumPendingBytes else {
            return false
        }
        let normalized = AgentPromptSubmissionPendingRequest(
            messageID: request.messageID,
            workspaceID: request.workspaceID,
            surfaceID: surfaceID ?? request.surfaceID,
            text: request.text,
            delivery: request.delivery
        )
        pendingByWorkspace[request.workspaceID, default: []].append(normalized)
        pendingBytes += requestBytes
        return true
    }
}
