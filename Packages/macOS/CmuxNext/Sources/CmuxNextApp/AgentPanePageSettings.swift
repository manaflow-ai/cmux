import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextDiff
import CmuxNextSettings
import Observation

/// The cmux.json keys every agent page shows, followed for ``AgentTabs``: `labs.previewFeatures`, `agentPane.needsYou.enabled`,
/// `agentPane.editedFiles.*`, `agentPane.showContextUsage`, `agentPane.spellChecking`, `diff.colors` and the Debug Settings
/// toggles `agent.reasoningSlider`/`agent.reasoningSliderStyle`/`agentPane.debug.sidebarPreviewVariant`. Each change reaches every open view; a new view gets the current
/// values (``apply(to:)``).
final class AgentPanePageSettings {
    private(set) var previewFeatures = false
    private(set) var editedFiles = AgentPaneEditedFilesSetting.fallback
    private(set) var zoom = AgentPaneZoomSetting.fallback
    private(set) var composer = AgentPaneComposerSetting.fallback
    private(set) var sidebarPreviewVariant = AgentPaneSidebarPreviewVariant.card
    /// Diff Colors (`diff.colors`), for the Changes view's added and removed lines.
    private(set) var diffColors = "theme"
    /// The chat's look (`agentPane.display.*` and the Markdown viewer keys it follows).
    private(set) var display = AgentPaneDisplaySetting.fallback
    private var displayObservation: Task<Void, Never>?
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
        for task in [previewObservation, editedFilesObservation, zoomObservation, composerObservation, reasoningSliderObservation, sidebarPreviewVariantObservation, diffColorsObservation, displayObservation] { task?.cancel() }  // a new controller replaces, never adds
        self.settings = settings
        // `sessions.promptSuggestions`: the pages, and the next acpmux daemon this app starts.
        AgentPaneSuggestedTasks.shared.setting = { [weak settings] in settings?.snapshot.sessions.promptSuggestions ?? SessionSettings.promptSuggestionsDefault }
        // `agentPane.needsYou.enabled` (App Store): read as each new agent page is made.
        AgentPaneTunables.needsYouInstalled = { [weak settings] in settings?.snapshot.agentPaneNeedsYouEnabled ?? false }
        previewObservation = observe({ settings.snapshot.previewFeatures }, push: push) { $0.previewFeatures = $1 }
        editedFilesObservation = observe({ settings.snapshot.agentPaneEditedFiles }, push: push) { $0.editedFiles = $1 }
        zoomObservation = observe({ settings.snapshot.agentPaneZoom }, push: push) { $0.zoom = $1 }
        composerObservation = Task { [weak self] in
            for await value in ObservationStream({ settings.snapshot.agentPaneComposer }) {
                guard let self else { return }
                // The reasoning slider is the Debug Settings toggle's, not cmux.json's.
                composer = value.keepingDebugToggles(of: composer)
                push()
            }
        }
        // task-owner: lives as long as the tabs; event-driven (Observation)
        reasoningSliderObservation = Task { [weak self] in
            for await on in ObservationStream({ (AgentPaneTunables.reasoningSlider.value, AgentPaneTunables.reasoningSliderStyle.value) }) {
                guard let self else { return }
                (composer.reasoningSlider, composer.reasoningSliderStyle) = (on.0, on.1.rawValue)
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
        AgentPaneComposerSetting.followLook(push) // Debug Settings' plain footer look
        // task-owner: lives as long as the tabs; event-driven (Observation)
        diffColorsObservation = Task { [weak self] in
            for await value in ObservationStream({ settings.fileRoot[DiffPrefKey.section]?["colors"] }) {
                guard let self else { return }
                diffColors = value.flatMap { DiffPrefKey.accepts("colors", $0) ? $0.stringValue : nil } ?? "theme"
                push()
            }
        }
        followDisplay(settings, push: push)
    }

    /// Follows the chat's look; split from ``follow(_:push:)``, which is at its size limit.
    private func followDisplay(_ settings: SettingsController, push: @escaping () -> Void) {
        // task-owner: lives as long as the tabs; event-driven (Observation)
        displayObservation = Task { [weak self] in
            for await value in ObservationStream({ AgentPaneDisplaySetting(fileRoot: settings.fileRoot) }) {
                guard let self, value != display else { continue }
                display = value
                push()
            }
        }
    }

    /// The Text & Width popover's write: one `agentPane.display.*` key at `path`, nil removes it.
    /// The observation above then pushes the new look to every page.
    func setDisplay(_ path: [String], _ value: JSONValue?) async throws {
        try await settings?.setSetting(at: path, to: value, by: .caller("page"))
    }

    /// One cmux.json value, followed: each change is stored by `store`, then `push` reaches the open views.
    private func observe<Value: Sendable>(_ read: @escaping @MainActor @Sendable () -> Value, push: @escaping () -> Void,
                                          store: @escaping (AgentPanePageSettings, Value) -> Void) -> Task<Void, Never> {
        // task-owner: lives as long as the tabs; event-driven (Observation)
        Task { [weak self] in
            for await value in ObservationStream(read) {
                guard let self else { return }
                store(self, value)
                push()
            }
        }
    }

    /// The composer's Hide or Show Context Usage and Hide dictation button: writes the flag at
    /// `path` (`agentPane.showContextUsage`, `agentPane.showDictation`), which the observation
    /// above then pushes to every page.
    func setComposer(_ path: [String], _ show: Bool) async throws {
        guard let settings else { return }
        let writer: SettingWriter = path == AgentPaneComposerSetting.scrollToBottomOnSendPath ? .user : .caller("page")
        try await settings.setSetting(at: path, to: .bool(show), by: writer)
    }

    /// Gives `view` the current values (the view pushes only a change).
    func apply(to view: AgentPaneView) {
        view.previewFeatures = previewFeatures
        view.editedFiles = editedFiles
        view.zoom = zoom
        sidebarPreviewVariant.push(to: view)
        composer.push(to: view)
        view.pushDiffColors(diffColors)
        // `sessions.allowFullAccess`, read per frame by the transport: a change applies at the next mode switch.
        view.model.transport.allowsFullAccess = { [weak self] in self?.settings?.snapshot.sessions.allowsFullAccess ?? true }
        view.pushDisplay(display)
    }
}
