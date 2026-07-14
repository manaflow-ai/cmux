import Foundation

nonisolated struct SurfaceResumeBindingIndex: Sendable {
    static let empty = SurfaceResumeBindingIndex(bindingsByPanel: [:])

    typealias PanelKey = RestorableAgentSessionIndex.PanelKey

    private let bindingsByPanel: [PanelKey: SurfaceResumeBindingSnapshot]
    private let bindingsByPanelId: [UUID: SurfaceResumeBindingSnapshot]

    init(bindingsByPanel: [PanelKey: SurfaceResumeBindingSnapshot]) {
        self.bindingsByPanel = bindingsByPanel
        var bindingsByPanelId: [UUID: SurfaceResumeBindingSnapshot] = [:]
        for (key, binding) in bindingsByPanel {
            let existing = bindingsByPanelId[key.panelId]
            if existing == nil || binding.updatedAt >= (existing?.updatedAt ?? 0) {
                bindingsByPanelId[key.panelId] = binding
            }
        }
        self.bindingsByPanelId = bindingsByPanelId
    }

    func binding(workspaceId: UUID, panelId: UUID) -> SurfaceResumeBindingSnapshot? {
        bindingsByPanel[PanelKey(workspaceId: workspaceId, panelId: panelId)] ?? bindingsByPanelId[panelId]
    }

    static func loadIncludingProcessDetectedBindings(
        fileManager: FileManager = .default,
        snapshotStore: CmuxTopProcessSnapshotStore = .shared
    ) async -> SurfaceResumeBindingIndex {
        let processSnapshot = await snapshotStore.snapshot(
            requirements: [.processDetails, .cmuxScope],
            maximumAge: 3,
            consumer: .processDetectedResume
        )
        return await Task.detached(priority: .utility) {
            let detectedBindings = processDetectedTmuxBindings(
                fileManager: fileManager,
                processSnapshot: processSnapshot,
                capturedAt: processSnapshot.sampledAt.timeIntervalSince1970
            )
            return SurfaceResumeBindingIndex(bindingsByPanel: detectedBindings.mapValues(\.binding))
        }.value
    }
}
