import Foundation

struct SurfaceResumeBindingIndex: Sendable {
    static let empty = SurfaceResumeBindingIndex(bindingsByPanel: [:])

    typealias PanelKey = RestorableAgentSessionIndex.PanelKey

    private let bindingsByPanel: [PanelKey: SurfaceResumeBindingSnapshot]
    private let bindingsByPanelId: [UUID: SurfaceResumeBindingSnapshot]

    init(bindingsByPanel: [PanelKey: SurfaceResumeBindingSnapshot]) {
        self.bindingsByPanel = bindingsByPanel
        var bindingsByPanelId: [UUID: SurfaceResumeBindingSnapshot] = [:]
        for (key, binding) in bindingsByPanel {
            guard let existing = bindingsByPanelId[key.panelId] else {
                bindingsByPanelId[key.panelId] = binding
                continue
            }
            if binding.isProcessDetected != existing.isProcessDetected {
                if binding.isProcessDetected { bindingsByPanelId[key.panelId] = binding }
                continue
            }
            if binding.updatedAt != existing.updatedAt {
                if binding.updatedAt > existing.updatedAt { bindingsByPanelId[key.panelId] = binding }
                continue
            }
            let incomingIdentity = "\(binding.kind ?? \"\"):\(binding.checkpointId ?? binding.command)"
            let existingIdentity = "\(existing.kind ?? \"\"):\(existing.checkpointId ?? existing.command)"
            if incomingIdentity > existingIdentity {
                bindingsByPanelId[key.panelId] = binding
            }
        }
        self.bindingsByPanelId = bindingsByPanelId
    }

    func binding(workspaceId: UUID, panelId: UUID) -> SurfaceResumeBindingSnapshot? {
        bindingsByPanel[PanelKey(workspaceId: workspaceId, panelId: panelId)] ?? bindingsByPanelId[panelId]
    }

    func binding(panelId: UUID) -> SurfaceResumeBindingSnapshot? {
        bindingsByPanelId[panelId]
    }

    /// Resolves a restart-stable panel while preferring a process-detected binding for its owner.
    func bindingForStablePanel(workspaceId: UUID, panelId: UUID) -> SurfaceResumeBindingSnapshot? {
        let exact = bindingsByPanel[PanelKey(workspaceId: workspaceId, panelId: panelId)]
        guard let exact else { return bindingsByPanelId[panelId] }
        if exact.isProcessDetected { return exact }
        return bindingsByPanelId[panelId] ?? exact
    }

    static func loadProcessDetectedBindingsSynchronously(
        fileManager: FileManager = .default
    ) -> SurfaceResumeBindingIndex {
        let detectedBindings = processDetectedTmuxBindings(fileManager: fileManager)
        return SurfaceResumeBindingIndex(bindingsByPanel: detectedBindings.mapValues(\.binding))
    }

    static func loadIncludingProcessDetectedBindings(
        fileManager: FileManager = .default
    ) async -> SurfaceResumeBindingIndex {
        await Task.detached(priority: .utility) {
            loadProcessDetectedBindingsSynchronously(fileManager: fileManager)
        }.value
    }
}
