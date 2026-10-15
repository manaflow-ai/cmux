import CmuxAgentChat
import Foundation

/// Posted on the main thread when an agent session's sidebar-visible facts
/// change (state, pane binding, title, last prompt, or the minute of its last
/// activity). The left sidebar refreshes the affected workspaces' snapshots
/// from it. Tool storms that only move `lastActivityAt` inside one minute do
/// not post, so a busy agent does not re-render its row per tool call.
struct AgentSessionSidebarDidChangeEvent: Sendable {
    static let notificationName = Notification.Name("cmux.agentSessionSidebarDidChange")

    /// Panel ids (the record's `surfaceID`) of the current and previous
    /// binding. Workspaces resolve membership by panel: workspace ids
    /// regenerate on relaunch while panel ids are stable.
    let panelIds: Set<UUID>
    /// Workspace ids named by the record, as a fallback when a panel id is missing.
    let workspaceIds: Set<UUID>

    init(panelIds: Set<UUID>, workspaceIds: Set<UUID>) {
        self.panelIds = panelIds
        self.workspaceIds = workspaceIds
    }

    init(current: AgentChatSessionRecord, previous: AgentChatSessionRecord?) {
        var panelIds = Set<UUID>()
        var workspaceIds = Set<UUID>()
        for record in [current, previous].compactMap({ $0 }) {
            if let panelId = record.surfaceID.flatMap(UUID.init(uuidString:)) {
                panelIds.insert(panelId)
            }
            if let workspaceId = record.workspaceID.flatMap(UUID.init(uuidString:)) {
                workspaceIds.insert(workspaceId)
            }
        }
        self.init(panelIds: panelIds, workspaceIds: workspaceIds)
    }

    init?(_ notification: Notification) {
        guard notification.name == Self.notificationName else { return nil }
        let panelIds = (notification.userInfo?["panelIds"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
        let workspaceIds = (notification.userInfo?["workspaceIds"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
        self.init(panelIds: Set(panelIds), workspaceIds: Set(workspaceIds))
    }

    func post(center: NotificationCenter = .default) {
        center.post(
            name: Self.notificationName,
            object: nil,
            userInfo: [
                "panelIds": panelIds.map(\.uuidString),
                "workspaceIds": workspaceIds.map(\.uuidString),
            ]
        )
    }

    /// The sidebar-visible projection of a record. Two records with equal
    /// fingerprints render the same row.
    struct Fingerprint: Equatable, Sendable {
        enum StateKind: Equatable, Sendable { case idle, working, needsInput, ended }

        let stateKind: StateKind
        let surfaceID: String?
        let workspaceID: String?
        let aiTitle: String?
        let lastPrompt: String?
        let lastPromptAt: Date?
        let lastActivityMinute: Date

        init(_ record: AgentChatSessionRecord) {
            switch record.state {
            case .idle: stateKind = .idle
            case .working: stateKind = .working
            case .needsInput: stateKind = .needsInput
            case .ended: stateKind = .ended
            }
            surfaceID = record.surfaceID
            workspaceID = record.workspaceID
            aiTitle = record.aiTitle
            lastPrompt = record.lastPrompt
            lastPromptAt = record.lastPromptAt
            lastActivityMinute = Self.flooredToMinute(record.lastActivityAt)
        }

        static func flooredToMinute(_ date: Date) -> Date {
            Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
        }
    }

    static func fingerprint(_ record: AgentChatSessionRecord) -> Fingerprint {
        Fingerprint(record)
    }
}
