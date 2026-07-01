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
    private let upsert: (ControlSidebarTabTarget, SidebarStatusEntry) -> Void
    private let clear: (ControlSidebarTabTarget, String) -> Void
    private let mapper: ClaudeSidebarStatusMapper

    init(registry: AgentChatSessionRegistry,
         upsert: @escaping (ControlSidebarTabTarget, SidebarStatusEntry) -> Void,
         clear: @escaping (ControlSidebarTabTarget, String) -> Void,
         mapper: ClaudeSidebarStatusMapper = ClaudeSidebarStatusMapper()) {
        self.upsert = upsert
        self.clear = clear
        self.mapper = mapper
        registry.addRecordChangeObserver { [weak self] record, _ in self?.apply(record) }
    }

    private func apply(_ record: AgentChatSessionRecord) {
        guard record.agentKind == .claude,
              let workspaceID = record.workspaceID,
              let uuid = UUID(uuidString: workspaceID) else { return }
        let target = ControlSidebarTabTarget.workspace(uuid)

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
}
