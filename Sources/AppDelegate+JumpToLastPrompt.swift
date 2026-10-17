import AppKit
import CmuxSidebar
import Foundation

/// "Jump to Last Prompt": focus the surface where the user most recently
/// submitted a prompt to a coding agent, across every workspace and window.
///
/// The source is each workspace's `panelPrompts`, which the prompt-submit hook
/// path (`TabManager.handlePromptSubmit`) stamps per panel for every agent that
/// reports `UserPromptSubmit`. Closing a panel drops its entry, and moving a
/// panel to another workspace carries it along, so a candidate that still
/// resolves to a live panel is always a surface the user can return to.
///
/// The ⌘⇧B shortcut, the View menu item and `surface.jump_to_last_prompt` all
/// go through ``AppDelegate/jumpToLastPrompt()``.
extension AppDelegate {
    /// One panel with a recorded prompt submit.
    struct LastPromptTarget: Equatable, Sendable {
        let workspaceId: UUID
        let panelId: UUID
        let submittedAt: Date

        /// The most recent submit. Equal timestamps resolve by workspace id,
        /// then panel id, so the choice never depends on dictionary order.
        nonisolated static func newest(in candidates: [LastPromptTarget]) -> LastPromptTarget? {
            candidates.min(by: isNewer)
        }

        /// Every candidate, most recent submit first, in the same order
        /// ``newest(in:)`` picks from.
        nonisolated static func newestFirst(_ candidates: [LastPromptTarget]) -> [LastPromptTarget] {
            candidates.sorted(by: isNewer)
        }

        private nonisolated static func isNewer(_ lhs: LastPromptTarget, than rhs: LastPromptTarget) -> Bool {
            if lhs.submittedAt != rhs.submittedAt { return lhs.submittedAt > rhs.submittedAt }
            if lhs.workspaceId != rhs.workspaceId { return lhs.workspaceId.uuidString < rhs.workspaceId.uuidString }
            return lhs.panelId.uuidString < rhs.panelId.uuidString
        }
    }

    /// Every live panel with a recorded prompt, across all windows, most
    /// recent submit first.
    func lastPromptTargetsNewestFirst() -> [LastPromptTarget] {
        let candidates = liveWorkspaceIdentityTabManagers().flatMap { manager in
            manager.tabs.flatMap { $0.lastPromptTargets }
        }
        return LastPromptTarget.newestFirst(candidates)
    }

    /// Selects the workspace (and its window) and focuses the surface of the
    /// most recent prompt. A window that is briefly detached cannot take
    /// focus, so the next most recent target is tried instead. Returns the
    /// target it focused, or nil when none would take focus.
    @discardableResult
    func jumpToLastPrompt() -> LastPromptTarget? {
        lastPromptTargetsNewestFirst().first { target in
            focusTerminal(tabId: target.workspaceId, surfaceId: target.panelId)
        }
    }

    /// Keyboard and menu entry point: beeps when there is nowhere to jump.
    func jumpToLastPromptFromUserCommand() {
        if jumpToLastPrompt() == nil {
            NSSound.beep()
        }
    }
}

extension Workspace {
    /// This workspace's panels that still exist and have a recorded prompt.
    var lastPromptTargets: [AppDelegate.LastPromptTarget] {
        panelPrompts.compactMap { panelId, prompt in
            guard panels[panelId] != nil else { return nil }
            return AppDelegate.LastPromptTarget(
                workspaceId: id,
                panelId: panelId,
                submittedAt: prompt.submittedAt
            )
        }
    }
}
