import CmuxNextAgentPane
import CmuxNextSettings
import Observation

/// The cmux.json keys every agent page shows, followed for ``AgentTabs``: `labs.previewFeatures`
/// and `agentPane.editedFiles.*`. Each change reaches every open view; a new view gets the current
/// values (``apply(to:)``).
final class AgentPanePageSettings {
    private(set) var previewFeatures = false
    private(set) var editedFiles = AgentPaneEditedFilesSetting.fallback
    private(set) var zoom = AgentPaneZoomSetting.fallback
    private var previewObservation: Task<Void, Never>?
    private var editedFilesObservation: Task<Void, Never>?
    private var zoomObservation: Task<Void, Never>?

    /// Follows both keys in `settings`; `push` runs after each change, to reach the open views.
    func follow(_ settings: SettingsController, push: @escaping () -> Void) {
        // task-owner: lives as long as the tabs; event-driven (Observation)
        previewObservation = Task { [weak self] in
            for await on in Observations({ settings.snapshot.previewFeatures }) {
                guard let self else { return }
                previewFeatures = on
                push()
            }
        }
        // task-owner: lives as long as the tabs; event-driven (Observation)
        editedFilesObservation = Task { [weak self] in
            for await value in Observations({ settings.snapshot.agentPaneEditedFiles }) {
                guard let self else { return }
                editedFiles = value
                push()
            }
        }
        // task-owner: lives as long as the tabs; event-driven (Observation)
        zoomObservation = Task { [weak self] in
            for await value in Observations({ settings.snapshot.agentPaneZoom }) {
                guard let self else { return }
                zoom = value
                push()
            }
        }
    }

    /// Gives `view` the current values (the view pushes only a change).
    func apply(to view: AgentPaneView) {
        view.previewFeatures = previewFeatures
        view.editedFiles = editedFiles
        view.zoom = zoom
    }
}
