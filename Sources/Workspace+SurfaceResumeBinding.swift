import Foundation

extension Workspace {
    @discardableResult
    func setSurfaceResumeBinding(
        _ binding: SurfaceResumeBindingSnapshot,
        panelId: UUID
    ) -> Bool {
        guard terminalPanel(for: panelId) != nil,
              let startupInput = binding.inlineStartupInput(repairPortableAgentExecutable: false),
              !startupInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        surfaceResumeBindingsByPanelId[panelId] = binding
        agentSessionRetryCoordinator.managedResumeBindingDidChange(
            panelId: panelId,
            binding: binding.isAgentHookBinding ? binding : nil
        )
        return true
    }

    @discardableResult
    func clearSurfaceResumeBinding(
        panelId: UUID,
        agentSessionEnded: Bool = false
    ) -> Bool {
        guard let binding = surfaceResumeBindingsByPanelId.removeValue(forKey: panelId) else {
            return false
        }
        agentSessionRetryCoordinator.managedResumeBindingDidClear(
            panelId: panelId,
            binding: binding,
            sessionDidEnd: agentSessionEnded
        )
        return true
    }

    func surfaceResumeBinding(panelId: UUID) -> SurfaceResumeBindingSnapshot? {
        surfaceResumeBindingsByPanelId[panelId]
    }
}
