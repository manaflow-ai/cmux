import CmuxMobileHost
import Foundation

/// A settled agent session that can be closed without losing its restore history.
struct SettledSessionCloseCandidate: Identifiable {
    let id: String
    let workspace: Workspace
    let panelID: UUID
    let record: AgentChatSessionRecord
}

enum SettledSessionClosePolicy {
    @MainActor
    static func isEligible(
        record: AgentChatSessionRecord,
        hibernationRecord: AgentHibernationRecord?,
        now: Date,
        idleHours: Double
    ) -> Bool {
        let threshold = max(1, idleHours) * 60 * 60
        let idleFor = AgentSessionListPayload.idleForSeconds(record: record, now: now)
        guard AgentSessionListPayload.isSettled(record: record, idleFor: idleFor, threshold: threshold) else {
            return false
        }
        // Reuse the hibernation process-scope evidence. It is the same safety
        // boundary used for automatic agent teardown and catches unsent input,
        // unrelated processes, and incomplete process ownership.
        guard let hibernationRecord,
              !hibernationRecord.hasUnconfirmedTerminalInput,
              !hibernationRecord.containsUnrelatedProcess,
              hibernationRecord.lifecycle.allowsHibernation,
              hibernationRecord.processSafetyAllowsHibernation else {
            return false
        }
        return true
    }
}

@MainActor
extension AppDelegate {
    func settledSessionCloseCandidates(now: Date = Date()) -> [SettledSessionCloseCandidate] {
        guard let records = TerminalController.shared.agentChatTranscriptService?.sessionRecords(workspaceID: nil) else {
            return []
        }
        let index = SharedLiveAgentIndex.shared.index ?? .empty
        let idleHours = AgentHibernationSettings.settledAutoCloseIdleHours()
        let threshold = max(1, idleHours) * 60 * 60
        let workspaces = workspacesForRead(tabIds: Set(records.compactMap { $0.workspaceID.flatMap(UUID.init(uuidString:)) }))
        let prefiltered: [(record: AgentChatSessionRecord, workspace: Workspace, panelID: UUID)] = records.compactMap { record in
            guard let workspaceID = record.workspaceID.flatMap(UUID.init(uuidString:)),
                  let surfaceID = record.surfaceID.flatMap(UUID.init(uuidString:)),
                  let workspace = workspaces[workspaceID],
                  workspace.panels[surfaceID] is TerminalPanel else { return nil }
            let idleFor = AgentSessionListPayload.idleForSeconds(record: record, now: now)
            guard AgentSessionListPayload.isSettled(record: record, idleFor: idleFor, threshold: threshold) else {
                return nil
            }
            return (record, workspace, surfaceID)
        }
        guard !prefiltered.isEmpty else { return [] }
        let hibernationRecords = agentHibernationRecords(
            index: index,
            activityByPanel: AgentHibernationController.shared.activityByPanel,
            terminalInputByPanel: AgentHibernationController.shared.terminalInputByPanel,
            lifecycleChangeByPanel: AgentHibernationController.shared.lifecycleChangeByPanel
        )
        let hibernationByKey = Dictionary(uniqueKeysWithValues: hibernationRecords.map { ($0.key, $0) })
        var candidates: [SettledSessionCloseCandidate] = []
        for item in prefiltered {
            let record = item.record
            let surfaceID = item.panelID
            let workspace = item.workspace
            let workspaceID = workspace.id
            let key = AgentHibernationPanelKey(workspaceId: workspaceID, panelId: surfaceID)
            guard SettledSessionClosePolicy.isEligible(
                record: record,
                hibernationRecord: hibernationByKey[key],
                now: now,
                idleHours: idleHours
            ) else { continue }
            candidates.append(.init(id: record.sessionID, workspace: workspace, panelID: surfaceID, record: record))
        }
        return candidates
    }

    func settledSessionCloseCandidateCounts(now: Date = Date()) -> [UUID: Int] {
        Dictionary(grouping: settledSessionCloseCandidates(now: now), by: { $0.workspace.id })
            .mapValues(\.count)
    }

    @discardableResult
    func closeSettledSessions(now: Date = Date(), automatic: Bool = false) -> Int {
        guard automatic ? AgentHibernationSettings.settledAutoCloseEnabled() : true else { return 0 }
        let candidates = settledSessionCloseCandidates(now: now)
        let latestCandidates = Dictionary(
            uniqueKeysWithValues: settledSessionCloseCandidates(now: Date()).map { ($0.id, $0) }
        )
        var closed: [SettledSessionCloseCandidate] = []
        for candidate in candidates {
            guard let latest = latestCandidates[candidate.id] else { continue }
            latest.workspace.markCloseHistoryEligible(panelId: latest.panelID)
            guard latest.workspace.closePanel(latest.panelID, force: true) else { continue }
            closed.append(latest)
        }
        guard !closed.isEmpty else { return 0 }
        let names = closed.map { $0.workspace.title }.joined(separator: ", ")
        let title = String(localized: "notification.settledSessions.closed.title", defaultValue: "Settled sessions closed")
        let body = String(
            format: String(localized: "notification.settledSessions.closed.body", defaultValue: "Closed: %@"),
            names
        )
        if let first = closed.first {
            TerminalNotificationStore.shared.addNotification(
                tabId: first.workspace.id,
                surfaceId: nil,
                title: title,
                subtitle: "",
                body: body,
                cooldownKey: automatic ? "settled-sessions-auto-close" : nil,
                cooldownInterval: automatic ? 60 : nil
            )
        }
        return closed.count
    }
}
