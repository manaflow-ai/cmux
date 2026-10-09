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
            candidates.max { lhs, rhs in
                if lhs.submittedAt != rhs.submittedAt { return lhs.submittedAt < rhs.submittedAt }
                if lhs.workspaceId != rhs.workspaceId { return lhs.workspaceId.uuidString > rhs.workspaceId.uuidString }
                return lhs.panelId.uuidString > rhs.panelId.uuidString
            }
        }
    }

    /// The surface the user last sent a prompt from, or nil when no live panel
    /// in any window has a recorded prompt.
    func lastPromptTarget() -> LastPromptTarget? {
        let candidates = liveWorkspaceIdentityTabManagers().flatMap { manager in
            manager.tabs.flatMap { $0.lastPromptTargets }
        }
        return LastPromptTarget.newest(in: candidates)
    }

    /// Selects the workspace (and its window) and focuses the surface of the
    /// most recent prompt. Returns the target it focused, or nil when there is
    /// none or the focus did not land.
    @discardableResult
    func jumpToLastPrompt() -> LastPromptTarget? {
        guard let target = lastPromptTarget(),
              focusTerminal(tabId: target.workspaceId, surfaceId: target.panelId) else {
            return nil
        }
        return target
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
