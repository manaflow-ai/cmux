import Foundation
import Observation

enum WorkspaceShareAccessDecision: String, Equatable, Sendable {
    case allow
    case deny
}

enum WorkspaceShareAccessReceiveOutcome: Equatable, Sendable {
    case queued
    case duplicate
    case deniedOverflow
    case ignoredAfterStop
}

struct WorkspaceSharePendingAccess: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case pending
        case sending
        case failed
    }

    var id: String { request.userId }
    let request: WorkspaceShareAccessRequest
    fileprivate(set) var state: State
}

/// Main-actor state for the host's workspace chat pane.
///
/// Authenticated access requests intentionally live outside `messages`: a
/// Durable Object chat snapshot may replace remote chat history, but it must
/// never remove a pending host decision or send verified identity data back to
/// viewers.
@MainActor
@Observable
final class WorkspaceShareChatModel {
    typealias DecisionSender = @MainActor @Sendable (
        _ userID: String,
        _ decision: WorkspaceShareAccessDecision
    ) async throws -> Void

    static let maximumPendingAccessCount = 24
    static let maximumMessageCount = 50
    static let maximumMessageLength = 500

    let shareURL: URL
    private(set) var messages: [WorkspaceShareChatMessage] = []
    private(set) var pendingAccess: [WorkspaceSharePendingAccess] = []
    private(set) var isStopped = false

    @ObservationIgnored private let decisionSender: DecisionSender
    @ObservationIgnored private let onSendChat: @MainActor (String) -> Void
    @ObservationIgnored private let onStopSharing: @MainActor () -> Void
    @ObservationIgnored private var decisionTasksByUserID: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var didRequestStop = false

    init(
        shareURL: URL,
        decisionSender: @escaping DecisionSender,
        onSendChat: @escaping @MainActor (String) -> Void,
        onStopSharing: @escaping @MainActor () -> Void
    ) {
        self.shareURL = shareURL
        self.decisionSender = decisionSender
        self.onSendChat = onSendChat
        self.onStopSharing = onStopSharing
    }

    @discardableResult
    func receive(_ request: WorkspaceShareAccessRequest) -> WorkspaceShareAccessReceiveOutcome {
        guard !isStopped else { return .ignoredAfterStop }
        guard !pendingAccess.contains(where: { $0.request.userId == request.userId }) else {
            return .duplicate
        }
        guard pendingAccess.count < Self.maximumPendingAccessCount else {
            return .deniedOverflow
        }
        pendingAccess.append(WorkspaceSharePendingAccess(request: request, state: .pending))
        return .queued
    }

    /// Starts one decision send. A failed send leaves the card visible so the
    /// host can retry; a successful send removes it. Each generation check
    /// prevents a late completion from reviving state after shutdown.
    @discardableResult
    func decide(
        userID: String,
        as decision: WorkspaceShareAccessDecision
    ) -> Task<Void, Never>? {
        guard !isStopped,
              decisionTasksByUserID[userID] == nil,
              let index = pendingAccess.firstIndex(where: { $0.request.userId == userID }),
              pendingAccess[index].state != .sending else { return nil }

        pendingAccess[index].state = .sending
        let decisionSender = decisionSender
        let decisionGeneration = generation
        let task = Task { @MainActor [weak self] in
            let result: Result<Void, any Error>
            do {
                try await decisionSender(userID, decision)
                result = .success(())
            } catch {
                result = .failure(error)
            }

            guard let self,
                  !Task.isCancelled,
                  !self.isStopped,
                  self.generation == decisionGeneration else { return }
            self.decisionTasksByUserID[userID] = nil
            guard let currentIndex = self.pendingAccess.firstIndex(where: {
                $0.request.userId == userID && $0.state == .sending
            }) else { return }
            switch result {
            case .success:
                self.pendingAccess.remove(at: currentIndex)
            case .failure:
                self.pendingAccess[currentIndex].state = .failed
            }
        }
        decisionTasksByUserID[userID] = task
        return task
    }

    /// Replaces only remote chat history. Permission cards remain host-local.
    func replaceMessages(_ messages: [WorkspaceShareChatMessage]) {
        self.messages = Self.uniqueMessages(messages)
    }

    func append(_ message: WorkspaceShareChatMessage) {
        if let existingIndex = messages.firstIndex(where: { $0.id == message.id }) {
            messages[existingIndex] = message
        } else {
            messages.append(message)
        }
        if messages.count > Self.maximumMessageCount {
            messages.removeFirst(messages.count - Self.maximumMessageCount)
        }
    }

    @discardableResult
    func sendChat(_ rawText: String) -> Bool {
        guard !isStopped else { return false }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        onSendChat(String(trimmed.prefix(Self.maximumMessageLength)))
        return true
    }

    func stopSharing() {
        guard !didRequestStop else { return }
        didRequestStop = true
        onStopSharing()
    }

    /// Freezes the model before transport teardown and returns every unresolved
    /// authenticated request so the host can best-effort deny it while the
    /// owner socket is still connected.
    func freezeAndDrainPending() -> [WorkspaceShareAccessRequest] {
        guard !isStopped else { return [] }
        isStopped = true
        generation &+= 1
        let requests = pendingAccess.map(\.request)
        pendingAccess.removeAll(keepingCapacity: false)
        let tasks = decisionTasksByUserID.values
        decisionTasksByUserID.removeAll(keepingCapacity: false)
        for task in tasks {
            task.cancel()
        }
        return requests
    }

    private static func uniqueMessages(
        _ messages: [WorkspaceShareChatMessage]
    ) -> [WorkspaceShareChatMessage] {
        var seen = Set<String>()
        let uniqueNewestFirst = messages.reversed().filter { seen.insert($0.id).inserted }
        return Array(uniqueNewestFirst.reversed().suffix(maximumMessageCount))
    }
}
