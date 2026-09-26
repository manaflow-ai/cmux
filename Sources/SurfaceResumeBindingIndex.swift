import Foundation

struct SurfaceResumeBindingIndex: Sendable {
    static let empty = SurfaceResumeBindingIndex(bindingsByPanel: [:])
    static let unavailable = SurfaceResumeBindingIndex(bindingsByPanel: [:], isAvailable: false)

    typealias PanelKey = RestorableAgentSessionIndex.PanelKey

    private let bindingsByPanel: [PanelKey: SurfaceResumeBindingSnapshot]
    private let bindingsByPanelId: [UUID: SurfaceResumeBindingSnapshot]
    private let ambiguousPanelIds: Set<UUID>
    let isAvailable: Bool

    init(bindingsByPanel: [PanelKey: SurfaceResumeBindingSnapshot], isAvailable: Bool = true) {
        self.bindingsByPanel = bindingsByPanel
        self.isAvailable = isAvailable
        var candidatesByPanelId: [UUID: [SurfaceResumeBindingSnapshot]] = [:]
        for (key, binding) in bindingsByPanel {
            candidatesByPanelId[key.panelId, default: []].append(binding)
        }

        var bindingsByPanelId: [UUID: SurfaceResumeBindingSnapshot] = [:]
        var ambiguousPanelIds: Set<UUID> = []
        for (panelId, candidates) in candidatesByPanelId {
            guard var selected = candidates.first else {
                continue
            }
            for candidate in candidates.dropFirst() {
                if candidate.isProcessDetected != selected.isProcessDetected {
                    if candidate.isProcessDetected { selected = candidate }
                    continue
                }
                if candidate.updatedAt != selected.updatedAt {
                    if candidate.updatedAt > selected.updatedAt { selected = candidate }
                    continue
                }
                let candidateIdentity = "\(candidate.kind ?? ""):\(candidate.checkpointId ?? candidate.command)"
                let selectedIdentity = "\(selected.kind ?? ""):\(selected.checkpointId ?? selected.command)"
                if candidateIdentity > selectedIdentity { selected = candidate }
            }
            let processDetectedCount = candidates.reduce(into: 0) { count, candidate in
                if candidate.isProcessDetected { count += 1 }
            }
            let topRankCount = candidates.reduce(into: 0) { count, candidate in
                guard candidate.isProcessDetected == selected.isProcessDetected,
                      candidate.updatedAt == selected.updatedAt else {
                    return
                }
                count += 1
            }
            if processDetectedCount > 1 || topRankCount > 1 {
                ambiguousPanelIds.insert(panelId)
            }
            bindingsByPanelId[panelId] = selected
        }
        self.bindingsByPanelId = bindingsByPanelId
        self.ambiguousPanelIds = ambiguousPanelIds
    }

    var isEmpty: Bool {
        bindingsByPanel.isEmpty
    }

    func binding(workspaceId: UUID, panelId: UUID) -> SurfaceResumeBindingSnapshot? {
        bindingsByPanel[PanelKey(workspaceId: workspaceId, panelId: panelId)]
            ?? binding(panelId: panelId)
    }

    func binding(panelId: UUID) -> SurfaceResumeBindingSnapshot? {
        guard !ambiguousPanelIds.contains(panelId) else { return nil }
        return bindingsByPanelId[panelId]
    }

    func hasAmbiguousPanel(_ panelId: UUID) -> Bool {
        ambiguousPanelIds.contains(panelId)
    }

    /// Resolves a restart-stable panel while preferring a process-detected binding for its owner.
    func bindingForStablePanel(workspaceId: UUID, panelId: UUID) -> SurfaceResumeBindingSnapshot? {
        let exact = bindingsByPanel[PanelKey(workspaceId: workspaceId, panelId: panelId)]
        if let exact, exact.isProcessDetected { return exact }
        guard !ambiguousPanelIds.contains(panelId) else { return nil }
        return bindingsByPanelId[panelId] ?? exact
    }

    static func loadProcessDetectedBindingsSynchronously(
        processSnapshot: CmuxTopProcessSnapshot,
        fileManager: FileManager = .default
    ) -> SurfaceResumeBindingIndex {
        let detectedBindings = processDetectedTmuxBindings(fileManager: fileManager, processSnapshot: processSnapshot, capturedAt: processSnapshot.sampledAt.timeIntervalSince1970)
        return SurfaceResumeBindingIndex(bindingsByPanel: detectedBindings.mapValues(\.binding))
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    static func loadIncludingProcessDetectedBindings(
        fileManager: FileManager = .default
    ) async -> SurfaceResumeBindingIndex {
        let snapshot = await CmuxTopProcessSnapshot.capture(includeProcessDetails: true, includeResources: false)
        return loadProcessDetectedBindingsSynchronously(processSnapshot: snapshot, fileManager: fileManager)
    }
}
