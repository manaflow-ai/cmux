public import Foundation

/// A per-panel index of the surface-resume bindings cmux replays when restoring
/// terminal surfaces, keyed by both the full `(workspaceId, panelId)` pair and a
/// panel-id-only fallback used when no exact workspace match exists.
///
/// Pure `Sendable` value state. The two process-detection factories that build an
/// index from a live process scan stay app-side (they read app-target process
/// scanners); only this value-type core lives in the package.
nonisolated public struct SurfaceResumeBindingIndex: Sendable {
    /// An empty index carrying no bindings.
    public static let empty = SurfaceResumeBindingIndex(bindingsByPanel: [:])

    /// The per-panel key type, shared with `RestorableAgentSessionIndex`.
    public typealias PanelKey = WorkspacePanelKey

    private let bindingsByPanel: [PanelKey: SurfaceResumeBindingSnapshot]
    private let bindingsByPanelId: [UUID: SurfaceResumeBindingSnapshot]

    /// Builds an index from the per-panel bindings, deriving the panel-id-only
    /// fallback map by keeping the most recently updated binding for each panel id.
    public init(bindingsByPanel: [PanelKey: SurfaceResumeBindingSnapshot]) {
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

    /// The binding for `(workspaceId, panelId)`, falling back to the panel-id-only
    /// map when no exact workspace match exists.
    public func binding(workspaceId: UUID, panelId: UUID) -> SurfaceResumeBindingSnapshot? {
        bindingsByPanel[PanelKey(workspaceId: workspaceId, panelId: panelId)] ?? bindingsByPanelId[panelId]
    }
}
