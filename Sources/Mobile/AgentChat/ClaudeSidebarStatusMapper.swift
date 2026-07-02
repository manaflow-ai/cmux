import CmuxAgentChat
import CmuxSidebar
import Foundation

/// Pure mapping from a Claude session's `ChatAgentState` to a sidebar status-row decision.
/// Scoped to `.claude` ONLY — Codex/other kinds return `.ignore` so the CLI keeps owning their
/// (richer) rows. `.ended` clears; other states upsert using the verbatim constants.
nonisolated struct ClaudeSidebarStatusMapper {
    nonisolated enum Decision: Equatable {
        case upsert(SidebarStatusEntry)
        case clear(key: String)
        case ignore
    }

    func decision(for state: ChatAgentState, kind: ChatAgentKind) -> Decision {
        guard kind == .claude else { return .ignore }
        let key = ClaudeSidebarStatusConstants.statusKey
        switch state {
        case .ended:
            return .clear(key: key)
        case .idle:
            return .upsert(SidebarStatusEntry(
                key: key, value: ClaudeSidebarStatusConstants.idleValue,
                icon: ClaudeSidebarStatusConstants.idleIcon, color: ClaudeSidebarStatusConstants.idleColor,
                priority: ClaudeSidebarStatusConstants.idlePriority))
        case .working:
            return .upsert(SidebarStatusEntry(
                key: key, value: ClaudeSidebarStatusConstants.workingValue,
                icon: ClaudeSidebarStatusConstants.workingIcon, color: ClaudeSidebarStatusConstants.workingColor,
                priority: ClaudeSidebarStatusConstants.workingPriority))
        case .needsInput:
            return .upsert(SidebarStatusEntry(
                key: key, value: ClaudeSidebarStatusConstants.needsInputValue,
                icon: ClaudeSidebarStatusConstants.needsInputIcon, color: ClaudeSidebarStatusConstants.needsInputColor,
                priority: ClaudeSidebarStatusConstants.needsInputPriority))
        }
    }
}
