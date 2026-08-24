import CmuxTerminalCore
import Foundation

/// Owns the app-level admission queue for addressed agent prompts.
///
/// All admission and draining happens on the main actor because the terminal
/// surface and workspace topology are main-actor state. A request that cannot
/// safely touch the composer yet stays in this queue; it is never split into
/// separate writes and never competes with a human draft. The workspace key is
/// intentionally used as the serialization boundary, which is stronger than
/// the required per-surface guarantee when a workspace contains multiple
/// agent panes.
@MainActor
final class AgentPromptSubmissionService {
    typealias Delivery = @MainActor @Sendable () -> AgentPromptSubmissionResult

    struct Receipt: Sendable {
        let messageID: UUID
        let result: AgentPromptSubmissionResult
    }

    private struct PendingRequest {
        let messageID: UUID
        let workspaceID: UUID
        let surfaceID: UUID?
        let text: String
        let delivery: Delivery
    }

    private struct AcceptedMessage {
        let messageID: UUID
        let workspaceID: UUID
        let text: String
    }

    private let maximumPendingRequests: Int
    private let maximumAcceptedMessagesPerSurface = 64
    private let maximumTrackedSurfaces = 256
    private var pendingByWorkspace: [UUID: [PendingRequest]] = [:]
    private var acceptedBySurface: [UUID: [AcceptedMessage]] = [:]
    private var acceptedSurfaceOrder: [UUID] = []

    init(maximumPendingRequests: Int = 256) {
        self.maximumPendingRequests = max(1, maximumPendingRequests)
    }

    /// Admits one request and returns its stable message id immediately.
    ///
    /// The delivery closure is executed synchronously on the main actor when
    /// the workspace has no older pending request. Busy/temporarily-unready
    /// outcomes become queued receipts instead of errors, preserving the
    /// caller's message and the human's composer.
    func submit(
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        text: String,
        delivery: @escaping Delivery
    ) -> Receipt {
        let messageID = UUID()
        let request = PendingRequest(
            messageID: messageID,
            workspaceID: workspaceID,
            surfaceID: requestedSurfaceID,
            text: text,
            delivery: delivery
        )

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
            enqueue(request)
            return Receipt(
                messageID: messageID,
                result: .queued(
                    workspaceID: workspaceID,
                    surfaceID: requestedSurfaceID ?? pendingByWorkspace[workspaceID]?.first?.surfaceID,
                    reason: "workspace_fifo"
                )
            )
        }

        let result = delivery()
        switch result {
        case .rejectedComposerBusy(let resolvedWorkspaceID, let surfaceID):
            enqueue(request, surfaceID: surfaceID)
            return Receipt(
                messageID: messageID,
                result: .queued(
                    workspaceID: resolvedWorkspaceID,
                    surfaceID: surfaceID,
                    reason: "human_composer_busy"
                )
            )
        case .agentBusy(let resolvedWorkspaceID, let surfaceID):
            enqueue(request, surfaceID: surfaceID)
            return Receipt(
                messageID: messageID,
                result: .queued(
                    workspaceID: resolvedWorkspaceID,
                    surfaceID: surfaceID,
                    reason: "agent_turn_active"
                )
            )
        case .agentScopeUnavailable(let resolvedWorkspaceID, let surfaceID):
            // A scope gap is common while an agent is waking or rebinding. Keep
            // the request durable; the retry re-resolves the process identity.
            enqueue(request, surfaceID: surfaceID)
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
                enqueue(request, surfaceID: surfaceID)
                return Receipt(
                    messageID: messageID,
                    result: .queued(
                        workspaceID: resolvedWorkspaceID,
                        surfaceID: surfaceID,
                        reason: "runtime_starting"
                    )
                )
            }
            recordAccepted(
                messageID: messageID,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                text: text
            )
            return Receipt(
                messageID: messageID,
                result: .submitted(
                    workspaceID: resolvedWorkspaceID,
                    surfaceID: surfaceID,
                    queued: queued
                )
            )
        default:
            return Receipt(messageID: messageID, result: result)
        }
    }

    /// Retries requests waiting for a workspace. Returns completed receipts so
    /// the owner can publish success/failure events without giving the service
    /// a second global observer or notification dependency.
    @discardableResult
    func drain(workspaceID: UUID) -> [Receipt] {
        guard var pending = pendingByWorkspace[workspaceID], !pending.isEmpty else {
            pendingByWorkspace.removeValue(forKey: workspaceID)
            return []
        }

        var completed: [Receipt] = []
        while let first = pending.first {
            let result = first.delivery()
            switch result {
            case .rejectedComposerBusy, .agentBusy, .agentScopeUnavailable:
                pendingByWorkspace[workspaceID] = pending
                return completed
            case .submitted(let resolvedWorkspaceID, let surfaceID, let queued):
                if queued {
                    pendingByWorkspace[workspaceID] = pending
                    return completed
                }
                pending.removeFirst()
                recordAccepted(
                    messageID: first.messageID,
                    workspaceID: resolvedWorkspaceID,
                    surfaceID: surfaceID,
                    text: first.text
                )
                completed.append(
                    Receipt(
                        messageID: first.messageID,
                        result: .submitted(
                            workspaceID: resolvedWorkspaceID,
                            surfaceID: surfaceID,
                            queued: queued
                        )
                    )
                )
            default:
                // A vanished workspace/surface or a dead process is terminal
                // for this queued message. Do not silently retry forever.
                pending.removeFirst()
                completed.append(
                    Receipt(messageID: first.messageID, result: result)
                )
            }
        }

        pendingByWorkspace.removeValue(forKey: workspaceID)
        return completed
    }

    /// Matches the next accepted app message to an agent hook. Matching is
    /// FIFO for equal text and scoped to the exact surface, so a hook from one
    /// workspace cannot acknowledge another workspace's message.
    func confirm(
        workspaceID: UUID,
        surfaceID: UUID,
        message: String?
    ) -> UUID? {
        guard var accepted = acceptedBySurface[surfaceID], !accepted.isEmpty else {
            return nil
        }
        let normalizedMessage = Self.normalized(message)
        let index: Int?
        if let normalizedMessage {
            index = accepted.firstIndex {
                $0.workspaceID == workspaceID
                    && Self.normalized($0.text) == normalizedMessage
            }
        } else {
            index = accepted.firstIndex { $0.workspaceID == workspaceID }
        }
        guard let index else { return nil }
        let matched = accepted.remove(at: index)
        if accepted.isEmpty {
            acceptedBySurface.removeValue(forKey: surfaceID)
        } else {
            acceptedBySurface[surfaceID] = accepted
        }
        return matched.messageID
    }

    /// Drops queued and awaiting messages when a workspace is permanently
    /// closed. The owner can publish terminal failure receipts before calling
    /// this if it needs per-message diagnostics.
    @discardableResult
    func remove(workspaceID: UUID) -> [Receipt] {
        let pending = pendingByWorkspace.removeValue(forKey: workspaceID) ?? []
        var receipts = pending.map { request in
            Receipt(
                messageID: request.messageID,
                result: .workspaceNotFound(workspaceID: workspaceID)
            )
        }
        for (surfaceID, messages) in Array(acceptedBySurface) {
            let removed = messages.filter { $0.workspaceID == workspaceID }
            guard !removed.isEmpty else { continue }
            let remaining = messages.filter { $0.workspaceID != workspaceID }
            if remaining.isEmpty {
                acceptedBySurface.removeValue(forKey: surfaceID)
                acceptedSurfaceOrder.removeAll { $0 == surfaceID }
            } else {
                acceptedBySurface[surfaceID] = remaining
            }
            receipts.append(contentsOf: removed.map { message in
                Receipt(
                    messageID: message.messageID,
                    result: .workspaceNotFound(workspaceID: workspaceID)
                )
            })
        }
        return receipts
    }

    /// Releases hook-awaiting messages when a terminal surface is torn down.
    func remove(surfaceID: UUID) {
        acceptedBySurface.removeValue(forKey: surfaceID)
        acceptedSurfaceOrder.removeAll { $0 == surfaceID }
    }

    var pendingCount: Int {
        pendingByWorkspace.values.reduce(0) { $0 + $1.count }
    }

    private func enqueue(_ request: PendingRequest, surfaceID: UUID? = nil) {
        guard pendingCount < maximumPendingRequests else { return }
        let normalized = PendingRequest(
            messageID: request.messageID,
            workspaceID: request.workspaceID,
            surfaceID: surfaceID ?? request.surfaceID,
            text: request.text,
            delivery: request.delivery
        )
        pendingByWorkspace[request.workspaceID, default: []].append(normalized)
    }

    private func recordAccepted(
        messageID: UUID,
        workspaceID: UUID,
        surfaceID: UUID,
        text: String
    ) {
        var messages = acceptedBySurface[surfaceID, default: []]
        messages.append(
            AcceptedMessage(
                messageID: messageID,
                workspaceID: workspaceID,
                text: text
            )
        )
        if messages.count > maximumAcceptedMessagesPerSurface {
            messages.removeFirst(messages.count - maximumAcceptedMessagesPerSurface)
        }
        acceptedBySurface[surfaceID] = messages
        acceptedSurfaceOrder.removeAll { $0 == surfaceID }
        acceptedSurfaceOrder.append(surfaceID)
        while acceptedSurfaceOrder.count > maximumTrackedSurfaces {
            let evictedSurfaceID = acceptedSurfaceOrder.removeFirst()
            acceptedBySurface.removeValue(forKey: evictedSurfaceID)
        }
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let value = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return value.isEmpty ? nil : value
    }
}
