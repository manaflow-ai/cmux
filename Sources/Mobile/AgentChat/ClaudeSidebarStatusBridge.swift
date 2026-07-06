import CmuxAgentChat
import CmuxControlSocket
import CmuxSidebar
import Foundation

/// Bridges the cross-validated `AgentChatSessionRegistry` to the desktop sidebar's `claude_code`
/// row. Applies decisions through injected `upsert`/`clear` closures (wired to TerminalController's
/// controlSidebarScheduleStatusUpsert/Clear at composition — the SAME seam the CLI uses, so
/// last-writer-wins lands on one dict). Scoped to `.claude` with a parseable workspace UUID.
@MainActor
final class ClaudeSidebarStatusBridge {
    private let registry: AgentChatSessionRegistry
    private let upsert: (ControlSidebarTabTarget, SidebarStatusEntry) -> Void
    private let clear: (ControlSidebarTabTarget, String) -> Void
    private let mapper: ClaudeSidebarStatusMapper

    init(registry: AgentChatSessionRegistry,
         upsert: @escaping (ControlSidebarTabTarget, SidebarStatusEntry) -> Void,
         clear: @escaping (ControlSidebarTabTarget, String) -> Void,
         mapper: ClaudeSidebarStatusMapper = ClaudeSidebarStatusMapper()) {
        self.registry = registry
        self.upsert = upsert
        self.clear = clear
        self.mapper = mapper
        registry.addRecordChangeObserver { [weak self] record, previous in
            self?.handleRecordChange(record, previous: previous)
        }
        replayCurrentRecords()
    }

    private func replayCurrentRecords() {
        let workspaceIDs = Set(registry.sessions(workspaceID: nil).compactMap(Self.claudeWorkspaceID))
        for workspaceID in workspaceIDs { applyWorkspaceStatus(workspaceID) }
    }

    private func handleRecordChange(_ record: AgentChatSessionRecord, previous: AgentChatSessionRecord?) {
        var workspaceIDs = Set<UUID>()
        if let workspaceID = Self.claudeWorkspaceID(record) { workspaceIDs.insert(workspaceID) }
        if let previous, let workspaceID = Self.claudeWorkspaceID(previous) {
            workspaceIDs.insert(workspaceID)
        }
        for workspaceID in workspaceIDs { applyWorkspaceStatus(workspaceID) }
    }

    private func applyWorkspaceStatus(_ workspaceID: UUID) {
        let activeClaudeRecords = registry.sessions(workspaceID: workspaceID.uuidString)
            .filter { $0.agentKind == .claude && !Self.isEnded($0.state) }
        guard let latest = activeClaudeRecords.max(by: Self.statusSortPrecedes) else {
            clear(.workspace(workspaceID), ClaudeSidebarStatusConstants.statusKey)
            return
        }
        apply(latest, target: .workspace(workspaceID))
    }

    private func apply(_ record: AgentChatSessionRecord, target: ControlSidebarTabTarget) {
        switch mapper.decision(for: record.state, kind: record.agentKind) {
        case let .upsert(entry):
            // No reaper to arm: the registry's own per-PID exit watcher
            // (DispatchSourceProcess) flips the session to `.ended` on process
            // exit, which arrives here as a `.clear` decision.
            upsert(target, entry)
        case let .clear(key):
            clear(target, key)
        case .ignore:
            break
        }
    }

    private static func claudeWorkspaceID(_ record: AgentChatSessionRecord) -> UUID? {
        guard record.agentKind == .claude,
              let workspaceID = record.workspaceID else { return nil }
        return UUID(uuidString: workspaceID)
    }

    private static func isEnded(_ state: ChatAgentState) -> Bool {
        if case .ended = state { return true }
        return false
    }

    private static func statusSortPrecedes(_ lhs: AgentChatSessionRecord, _ rhs: AgentChatSessionRecord) -> Bool {
        let lhsPriority = statusPriority(lhs.state)
        let rhsPriority = statusPriority(rhs.state)
        if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
        return lhs.lastActivityAt < rhs.lastActivityAt
    }

    private static func statusPriority(_ state: ChatAgentState) -> Int {
        switch state {
        case .needsInput:
            return 3
        case .working:
            return 2
        case .idle:
            return 1
        case .ended:
            return 0
        }
    }
}
