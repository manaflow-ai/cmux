import CMUXAgentLaunch
import CmuxInbox
import Foundation
import Observation

@MainActor
final class InboxFeedMirror {
    private let hub: IntegrationHub
    private let identity = InboxIdentity()
    private var storeObserver: NSObjectProtocol?
    private var mirroredItemIDs = Set<UUID>()

    init(hub: IntegrationHub) {
        self.hub = hub
    }

    deinit {
        if let storeObserver {
            NotificationCenter.default.removeObserver(storeObserver)
        }
    }

    func start() {
        storeObserver = NotificationCenter.default.addObserver(
            forName: FeedCoordinator.storeInstalledNotification,
            object: FeedCoordinator.shared,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.observeCurrentStore() }
        }
        observeCurrentStore()
    }

    private func observeCurrentStore() {
        guard let store = FeedCoordinator.shared.store else { return }
        withObservationTracking {
            _ = store.items.map(\.id)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.mirror(store.items)
                self?.observeCurrentStore()
            }
        }
        mirror(store.items)
    }

    private func mirror(_ items: [WorkstreamItem]) {
        for item in items where mirroredItemIDs.insert(item.id).inserted {
            let mapped = mappedRecords(for: item)
            Task { [hub] in
                try? await hub.push(account: mapped.account, thread: mapped.thread, item: mapped.item)
            }
        }
    }

    private func mappedRecords(for item: WorkstreamItem) -> (account: InboxAccount, thread: InboxThread, item: InboxItem) {
        let accountID = item.source.rawValue
        let threadID = identity.threadID(
            source: .agent,
            accountID: accountID,
            externalThreadID: item.workstreamId
        )
        let account = InboxAccount(
            source: .agent,
            accountID: accountID,
            displayName: InboxLocalized.agentSourceLabel(item.source),
            status: .connected,
            capabilities: [.liveEvents, .backfill, .deepLink]
        )
        let thread = InboxThread(
            threadID: threadID,
            source: .agent,
            accountID: accountID,
            externalThreadID: item.workstreamId,
            participants: [InboxParticipant(displayName: InboxLocalized.agentSourceLabel(item.source))],
            title: item.title ?? item.workstreamId,
            lastActivityAt: item.updatedAt,
            metadata: ["workstream_id": item.workstreamId]
        )
        let inboxItem = InboxItem(
            itemID: identity.itemID(
                source: .agent,
                accountID: accountID,
                externalMessageID: item.id.uuidString
            ),
            threadID: threadID,
            source: .agent,
            accountID: accountID,
            externalMessageID: item.id.uuidString,
            sender: InboxParticipant(displayName: InboxLocalized.agentSourceLabel(item.source)),
            timestamp: item.createdAt,
            bodyPreview: Self.preview(for: item),
            body: Self.body(for: item),
            metadata: [
                "workstream_id": item.workstreamId,
                "kind": item.kind.rawValue,
                "status": Self.statusLabel(item.status),
            ],
            isUnread: item.status.isPending,
            isActionable: item.kind.isActionable
        )
        return (account, thread, inboxItem)
    }

    private static func preview(for item: WorkstreamItem) -> String {
        switch item.payload {
        case .permissionRequest(_, let toolName, _, _):
            return String(localized: "inbox.agent.preview.permission", defaultValue: "Permission requested for \(toolName)")
        case .exitPlan:
            return String(localized: "inbox.agent.preview.exitPlan", defaultValue: "Plan approval requested")
        case .question(_, let questions):
            return questions.first?.prompt ?? String(localized: "inbox.agent.preview.question", defaultValue: "Question needs an answer")
        case .toolUse(let toolName, _):
            return String(localized: "inbox.agent.preview.toolUse", defaultValue: "Using \(toolName)")
        case .toolResult(let toolName, _, let isError):
            return isError
                ? String(localized: "inbox.agent.preview.toolError", defaultValue: "\(toolName) failed")
                : String(localized: "inbox.agent.preview.toolResult", defaultValue: "\(toolName) finished")
        case .userPrompt(let text), .assistantMessage(let text):
            return text
        case .sessionStart:
            return String(localized: "inbox.agent.preview.sessionStart", defaultValue: "Session started")
        case .sessionEnd:
            return String(localized: "inbox.agent.preview.sessionEnd", defaultValue: "Session ended")
        case .stop(let reason):
            return reason ?? String(localized: "inbox.agent.preview.stop", defaultValue: "Agent stopped")
        case .todos(let todos):
            return String(localized: "inbox.agent.preview.todos", defaultValue: "\(todos.count) todos updated")
        }
    }

    private static func body(for item: WorkstreamItem) -> String {
        [
            item.context?.lastUserMessage,
            item.context?.assistantPreamble,
            preview(for: item),
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    private static func statusLabel(_ status: WorkstreamStatus) -> String {
        switch status {
        case .pending: return "pending"
        case .resolved: return "resolved"
        case .expired: return "expired"
        case .telemetry: return "telemetry"
        }
    }
}
