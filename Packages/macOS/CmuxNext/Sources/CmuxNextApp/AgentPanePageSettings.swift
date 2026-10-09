import CmuxNextAgentPane
import CmuxNextSettings
import Observation

/// The cmux.json keys every agent page shows, followed for ``AgentTabs``: `labs.previewFeatures`,
/// `agentPane.editedFiles.*` and `agentPane.showContextUsage`. Each change reaches every open view; a new view gets the current
/// values (``apply(to:)``).
final class AgentPanePageSettings {
    private(set) var previewFeatures = false
    private(set) var editedFiles = AgentPaneEditedFilesSetting.fallback
    private(set) var composer = AgentPaneComposerSetting.fallback
    private var previewObservation: Task<Void, Never>?
    private var editedFilesObservation: Task<Void, Never>?
    private var composerObservation: Task<Void, Never>?
    /// Where the composer's Hide or Show Context Usage writes (``setShowContextUsage(_:)``).
    private weak var settings: SettingsController?

    /// Follows both keys in `settings`; `push` runs after each change, to reach the open views.
    func follow(_ settings: SettingsController, push: @escaping () -> Void) {
        self.settings = settings
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
        composerObservation = Task { [weak self] in
            for await value in Observations({ settings.snapshot.agentPaneComposer }) {
                guard let self else { return }
                composer = value
                push()
            }
        }
    }

    /// The composer's Hide or Show Context Usage: writes `agentPane.showContextUsage`, which the
    /// observation above then pushes to every page.
    func setShowContextUsage(_ show: Bool) async throws {
        try await settings?.set(.bool(show), at: AgentPaneComposerSetting.showContextUsagePath)
    }

    /// Gives `view` the current values (the view pushes only a change).
    func apply(to view: AgentPaneView) {
        view.previewFeatures = previewFeatures
        view.editedFiles = editedFiles
        view.composer = composer
    }
}
