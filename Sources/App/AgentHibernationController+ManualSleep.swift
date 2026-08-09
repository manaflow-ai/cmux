import Foundation

extension AppDelegate {
    /// Finds a workspace by id across every window's tab manager, mirroring the
    /// traversal `agentHibernationRecords(index:...)` uses.
    func workspace(forId workspaceId: UUID) -> Workspace? {
        for context in mainWindowContexts.values {
            if let match = context.tabManager.tabs.first(where: { $0.id == workspaceId }) {
                return match
            }
        }
        return tabManager?.tabs.first { $0.id == workspaceId }
    }
}

extension AgentHibernationController {
    /// Whether Sleep should be offered for this panel. Resolves the owning
    /// workspace so menu code holding only ids can ask without reaching for a
    /// `Workspace` reference of its own.
    func canSleepPanel(key: AgentHibernationPanelKey) -> Bool {
        guard let workspace = AppDelegate.shared?.workspace(forId: key.workspaceId) else {
            return false
        }
        return workspace.canSleepAgentPanel(panelId: key.panelId)
    }

    /// Puts the named panels to sleep on the user's behalf.
    ///
    /// This is the single shared action path behind every Sleep entrypoint, so
    /// new surfaces (command palette, CLI, a bindable shortcut) attach here
    /// rather than duplicating selection or teardown logic.
    ///
    /// The existing hibernation lifecycle remains the sole teardown owner. A
    /// manual request only changes *selection* (the user picked the panels) and
    /// *timing* (no idle settle window); transcript protection, process
    /// revalidation, and scoped termination are unchanged. Panels whose
    /// transcript cannot currently be protected are still skipped.
    @discardableResult
    func sleepPanels(keys: Set<AgentHibernationPanelKey>) -> Bool {
        guard !keys.isEmpty else { return false }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let index = await RestorableAgentSessionIndex
                .loadIncludingProcessDetectedSnapshots()
            guard !Task.isCancelled else { return }
            self.evaluate(
                index: index,
                settings: AgentHibernationSettings.values(),
                now: .now,
                trigger: .manual(keys)
            )
        }
        return true
    }
}
