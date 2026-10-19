import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextSettings
import Observation

/// The cmux.json keys every agent page shows, followed for ``AgentTabs``: `labs.previewFeatures`,
/// `agentPane.editedFiles.*`, `agentPane.showContextUsage`, `diff.colors` and the Debug Settings
/// toggles `agent.reasoningSlider`/`agent.reasoningSliderStyle`/`agent.modelMenu`/`agentPane.debug.sidebarPreviewVariant`. Each change reaches every open view; a new view gets the current
/// values (``apply(to:)``).
final class AgentPanePageSettings {
    private(set) var previewFeatures = false
    private(set) var editedFiles = AgentPaneEditedFilesSetting.fallback
    private(set) var zoom = AgentPaneZoomSetting.fallback
    private(set) var composer = AgentPaneComposerSetting.fallback
    private(set) var sidebarPreviewVariant = AgentPaneSidebarPreviewVariant.card
    /// Diff Colors (`diff.colors`), for the Changes view's added and removed lines.
    private(set) var diffColors = "theme"
    private var previewObservation: Task<Void, Never>?
    private var editedFilesObservation: Task<Void, Never>?
    private var zoomObservation: Task<Void, Never>?
    private var composerObservation: Task<Void, Never>?
    private var reasoningSliderObservation: Task<Void, Never>?
    private var sidebarPreviewVariantObservation: Task<Void, Never>?
    private var diffColorsObservation: Task<Void, Never>?
    /// Where the composer's Hide or Show Context Usage writes (``setComposer(_:_:)``).
    private weak var settings: SettingsController?

    /// Follows both keys in `settings`; `push` runs after each change, to reach the open views.
    func follow(_ settings: SettingsController, push: @escaping () -> Void) {
        for task in [previewObservation, editedFilesObservation, zoomObservation, composerObservation, reasoningSliderObservation, sidebarPreviewVariantObservation, diffColorsObservation] { task?.cancel() }  // a new controller replaces, never adds
        self.settings = settings
        // task-owner: lives as long as the tabs; event-driven (Observation)
        previewObservation = Task { [weak self] in
            for await on in ObservationStream({ settings.snapshot.previewFeatures }) {
                guard let self else { return }
                previewFeatures = on
                push()
            }
        }
        // task-owner: lives as long as the tabs; event-driven (Observation)
        editedFilesObservation = Task { [weak self] in
            for await value in ObservationStream({ settings.snapshot.agentPaneEditedFiles }) {
                guard let self else { return }
                editedFiles = value
                push()
            }
        }
        // task-owner: lives as long as the tabs; event-driven (Observation)
        zoomObservation = Task { [weak self] in
            for await value in ObservationStream({ settings.snapshot.agentPaneZoom }) {
                guard let self else { return }
                zoom = value
                push()
            }
        }
        composerObservation = Task { [weak self] in
            for await value in ObservationStream({ settings.snapshot.agentPaneComposer }) {
                guard let self else { return }
                // The reasoning slider is the Debug Settings toggle's, not cmux.json's.
                let reasoningSlider = composer.reasoningSlider
                let reasoningSliderStyle = composer.reasoningSliderStyle
                let modelMenu = composer.modelMenu
                composer = value
                composer.reasoningSlider = reasoningSlider
                composer.reasoningSliderStyle = reasoningSliderStyle
                composer.modelMenu = modelMenu
                push()
            }
        }
        // task-owner: lives as long as the tabs; event-driven (Observation)
        reasoningSliderObservation = Task { [weak self] in
            for await on in ObservationStream({ (AgentPaneTunables.reasoningSlider.value, AgentPaneTunables.reasoningSliderStyle.value, AgentPaneTunables.modelMenu.value) }) {
                guard let self else { return }
                composer.reasoningSlider = on.0
                composer.reasoningSliderStyle = on.1.rawValue
                composer.modelMenu = on.2.rawValue
                push()
            }
        }
        // task-owner: lives as long as the tabs; event-driven (Observation)
        sidebarPreviewVariantObservation = Task { [weak self] in
            for await on in ObservationStream({ AgentPaneTunables.sidebarPreviewVariant.value }) {
                guard let self else { return }
                sidebarPreviewVariant = on
                push()
            }
        }
        // task-owner: lives as long as the tabs; event-driven (Observation)
        diffColorsObservation = Task { [weak self] in
            for await value in ObservationStream({ settings.fileRoot[DiffPrefKey.section]?["colors"] }) {
                guard let self else { return }
                diffColors = value.flatMap { DiffPrefKey.accepts("colors", $0) ? $0.stringValue : nil } ?? "theme"
                push()
            }
        }
    }

    /// The composer's Hide or Show Context Usage and Hide dictation button: writes the flag at
    /// `path` (`agentPane.showContextUsage`, `agentPane.showDictation`), which the observation
    /// above then pushes to every page.
    func setComposer(_ path: [String], _ show: Bool) async throws {
        try await settings?.set(.bool(show), at: path)

    }

    /// Gives `view` the current values (the view pushes only a change).
    func apply(to view: AgentPaneView) {
        view.previewFeatures = previewFeatures
        view.editedFiles = editedFiles
        view.zoom = zoom
        sidebarPreviewVariant.push(to: view)
        composer.push(to: view)
        view.pushDiffColors(diffColors)
    }
}
