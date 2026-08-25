import CryptoKit
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
    /// One shared prompt-size limit for the socket parser and this service.
    static let maximumPromptBytes = 1_048_576
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
        let signature: Data
        let byteCount: Int
        let surfaceID: UUID
        let acceptedAt = Date()
    }

    private let maximumPendingRequests: Int
    private let maximumPendingBytes = 8 * 1_048_576
    private let maximumAcceptedMessagesPerSurface = 64
    private let maximumTrackedSurfaces = 256
    private let maximumAcceptedBytes = 8 * 1_048_576
    private var pendingByWorkspace: [UUID: [PendingRequest]] = [:]
    private var pendingBytes = 0
    private var acceptedBySurface: [UUID: [AcceptedMessage]] = [:]
    private var acceptedSurfaceOrder: [UUID] = []
    private var acceptedBytes = 0
    /// One accepted prompt at a time is the per-workspace FIFO barrier.
    private var inFlightByWorkspace: [UUID: AcceptedMessage] = [:]

    /// How long an accepted prompt may wait for its hook confirmation before
    /// it stops blocking the workspace FIFO. Confirmation is best-effort
    /// enrichment; an agent without cmux hooks (or one that decorates the
    /// submitted text) must not stall every later queued message.
    let confirmationTimeout: TimeInterval

    init(
        maximumPendingRequests: Int = 256,
        confirmationTimeout: TimeInterval = 30
    ) {
        self.maximumPendingRequests = max(1, maximumPendingRequests)
        self.confirmationTimeout = confirmationTimeout
    }

    /// Clears an unconfirmed accepted prompt after the confirmation window
    /// so a missing or unroutable hook cannot block `drain` forever. The
    /// accepted-message record is kept, so a late hook still confirms and
    /// carries the message id.
    @discardableResult
    func expireStaleInFlight(workspaceID: UUID, now: Date = Date()) -> UUID? {
        guard let inFlight = inFlightByWorkspace[workspaceID],
              now.timeIntervalSince(inFlight.acceptedAt) >= confirmationTimeout
        else { return nil }
        inFlightByWorkspace.removeValue(forKey: workspaceID)
        return inFlight.messageID
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
        let request = PendingRequest(
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
                    surfaceID: requestedSurfaceID ?? pendingByWorkspace[workspaceID]?.first?.surfaceID,
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

        let result = delivery()
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
            // A scope gap is common while an agent is waking or rebinding. Keep
            // the request durable; the retry re-resolves the process identity.
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
            recordAccepted(
                messageID: messageID,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                text: text
            )
            inFlightByWorkspace[workspaceID] = AcceptedMessage(
                messageID: messageID,
                workspaceID: workspaceID,
                signature: Self.messageSignature(text),
                byteCount: text.utf8.count,
                surfaceID: surfaceID
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
        expireStaleInFlight(workspaceID: workspaceID)
        guard inFlightByWorkspace[workspaceID] == nil else { return [] }
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
                pendingBytes = max(0, pendingBytes - first.text.utf8.count)
                recordAccepted(
                    messageID: first.messageID,
                    workspaceID: resolvedWorkspaceID,
                    surfaceID: surfaceID,
                    text: first.text
                )
                inFlightByWorkspace[workspaceID] = AcceptedMessage(
                    messageID: first.messageID,
                    workspaceID: resolvedWorkspaceID,
                    signature: Self.messageSignature(first.text),
                    byteCount: first.text.utf8.count,
                    surfaceID: surfaceID
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
                pendingBytes = max(0, pendingBytes - first.text.utf8.count)
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
        let messageSignature = message.map(Self.messageSignature)
        let index: Int?
        if let messageSignature {
            index = accepted.firstIndex {
                $0.workspaceID == workspaceID
                    && $0.signature == messageSignature
            }
        } else {
            index = accepted.firstIndex { $0.workspaceID == workspaceID }
        }
        guard let index else { return nil }
        let matched = accepted.remove(at: index)
        if inFlightByWorkspace[workspaceID]?.messageID == matched.messageID {
            inFlightByWorkspace.removeValue(forKey: workspaceID)
        }
        if accepted.isEmpty {
            acceptedBySurface.removeValue(forKey: surfaceID)
            acceptedSurfaceOrder.removeAll { $0 == surfaceID }
        } else {
            acceptedBySurface[surfaceID] = accepted
        }
        acceptedBytes = max(0, acceptedBytes - matched.byteCount)
        return matched.messageID
    }

    /// Drops queued and awaiting messages when a workspace is permanently
    /// closed. The owner can publish terminal failure receipts before calling
    /// this if it needs per-message diagnostics.
    @discardableResult
    func remove(workspaceID: UUID) -> [Receipt] {
        let pending = pendingByWorkspace.removeValue(forKey: workspaceID) ?? []
        pendingBytes = max(0, pendingBytes - pending.reduce(0) { $0 + $1.text.utf8.count })
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
        for (surfaceID, messages) in Array(acceptedBySurface) {
            let removed = messages.filter { $0.workspaceID == workspaceID }
            guard !removed.isEmpty else { continue }
            let remaining = messages.filter { $0.workspaceID != workspaceID }
            acceptedBytes = max(0, acceptedBytes - removed.reduce(0) { $0 + $1.byteCount })
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

    /// Releases messages tied to a terminal surface when it is torn down.
    @discardableResult
    func remove(surfaceID: UUID) -> [Receipt] {
        var receipts: [Receipt] = []
        for (workspaceID, pending) in Array(pendingByWorkspace) {
            let removed = pending.filter { $0.surfaceID == surfaceID }
            guard !removed.isEmpty else { continue }
            let remaining = pending.filter { $0.surfaceID != surfaceID }
            pendingBytes = max(0, pendingBytes - removed.reduce(0) { $0 + $1.text.utf8.count })
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
        if let removed = acceptedBySurface.removeValue(forKey: surfaceID) {
                acceptedBytes = max(0, acceptedBytes - removed.reduce(0) { $0 + $1.byteCount })
        }
        acceptedSurfaceOrder.removeAll { $0 == surfaceID }
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

    var pendingCount: Int {
        pendingByWorkspace.values.reduce(0) { $0 + $1.count }
    }

    private func enqueue(_ request: PendingRequest, surfaceID: UUID? = nil) -> Bool {
        let requestBytes = request.text.utf8.count
        guard pendingCount < maximumPendingRequests,
              pendingBytes + requestBytes <= maximumPendingBytes else {
            return false
        }
        let normalized = PendingRequest(
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

    private func recordAccepted(
        messageID: UUID,
        workspaceID: UUID,
        surfaceID: UUID,
        text: String
    ) {
        let textBytes = text.utf8.count
        let signature = Self.messageSignature(text)
        while acceptedBytes + textBytes > maximumAcceptedBytes,
              let oldestIndex = acceptedSurfaceOrder.firstIndex(where: { surfaceID in
                  !inFlightByWorkspace.values.contains { $0.surfaceID == surfaceID }
              }) {
            let oldestSurfaceID = acceptedSurfaceOrder.remove(at: oldestIndex)
            if let evicted = acceptedBySurface.removeValue(forKey: oldestSurfaceID) {
                acceptedBytes = max(0, acceptedBytes - evicted.reduce(0) { $0 + $1.byteCount })
            }
        }
        var messages = acceptedBySurface[surfaceID, default: []]
        messages.append(
            AcceptedMessage(
                messageID: messageID,
                workspaceID: workspaceID,
                signature: signature,
                byteCount: textBytes,
                surfaceID: surfaceID
            )
        )
        if messages.count > maximumAcceptedMessagesPerSurface {
            let removeCount = messages.count - maximumAcceptedMessagesPerSurface
            let removedBytes = messages.prefix(removeCount).reduce(0) { $0 + $1.byteCount }
            messages.removeFirst(removeCount)
            acceptedBytes = max(0, acceptedBytes - removedBytes)
        }
        acceptedBytes += textBytes
        acceptedBySurface[surfaceID] = messages
        acceptedSurfaceOrder.removeAll { $0 == surfaceID }
        acceptedSurfaceOrder.append(surfaceID)
        while acceptedSurfaceOrder.count > maximumTrackedSurfaces {
            guard let evictIndex = acceptedSurfaceOrder.firstIndex(where: { candidate in
                !inFlightByWorkspace.values.contains { $0.surfaceID == candidate }
            }) else { break }
            let evictedSurfaceID = acceptedSurfaceOrder.remove(at: evictIndex)
            if let evicted = acceptedBySurface.removeValue(forKey: evictedSurfaceID) {
                acceptedBytes = max(
                    0,
                    acceptedBytes - evicted.reduce(0) { $0 + $1.byteCount }
                )
            }
        }
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let value = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return value.isEmpty ? nil : value
    }

    private static func messageSignature(_ text: String) -> Data {
        let normalized = Self.normalized(text) ?? ""
        return Data(SHA256.hash(data: Data(normalized.utf8)))
    }
}
