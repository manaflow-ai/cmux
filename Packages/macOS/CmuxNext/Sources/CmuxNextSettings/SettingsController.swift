public import CmuxNextActions
public import CmuxNextAppearance
public import CmuxNextDesignTokens
public import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
public import Foundation
public import Observation

/// Loads `~/.config/cmux/cmux-next.json`, applies it to `DesignSettings` and the
/// action registry, and re-applies on every change to the file (kernel file
/// events, no polling). Writes go through `file` and come back through the
/// watcher, so the file stays the single source of truth.
///
/// App entry point:
/// ```swift
/// let settings = SettingsController(registry: registry)
/// settings.start()   // loads once, then watches
/// ```
@MainActor
@Observable
public final class SettingsController {
    /// Serialized, off-main file access (also backs `settings.get/set`).
    @ObservationIgnored public let file: CmuxConfigFile
    /// Diagnostics from the last load: bad values, unknown action IDs,
    /// unsupported chords, and shortcut conflicts.
    public private(set) var diagnostics: [SettingsDiagnostic] = []
    /// The last snapshot that loaded (even if nothing changed).
    public private(set) var snapshot: CmuxConfigSnapshot = .empty
    /// The dotted key the palette previews now (`preview`), or nil.
    public internal(set) var previewingKey: String?
    /// The snapshot a preview shows, or nil while none does (`preview`).
    public internal(set) var previewSnapshot: CmuxConfigSnapshot?
    /// The settings in effect: a preview's snapshot while one shows, else the loaded one. Live
    /// appearance the applier does not own (themes, the accent) follows this, so a preview shows.
    public var applied: CmuxConfigSnapshot { previewSnapshot ?? snapshot }
    /// Number of completed loads; tests and the App can await changes by it.
    public private(set) var loadCount = 0
    /// Keys an MDM profile or the team policy manages (dotted key -> manager).
    public private(set) var managedKeys: [String: ManagedSource] = [:]
    /// Managed policy keys that are not settings (`EnrollmentToken`, `DisabledFeatures`, ...).
    public private(set) var managedChatRoots: [String] = []
    /// Managed policy values outside the settings schema.
    public private(set) var managedPolicy: [String: JSONValue] = [:]
    /// The user's own cmux-next.json document; `snapshot.root` is the effective one.
    public private(set) var fileRoot: JSONValue = .object([:])
    /// The app's native confirmation for a socket write of a user-only key (`cmux settings set
    /// --confirm`): it shows a sheet that names the key and value and needs a real click or key.
    @ObservationIgnored public var userOnlyConfirmation: (@MainActor (String, JSONValue?) async -> Bool)?
    /// The Ghostty config files' own `background-blur` (C encoding), before cmux.json's: an
    /// opacity write with Material unset names the material it gives, and an opacity reset drops
    /// only that material (`WindowBackgroundSetting.linkedEdits`). Nil reads as no blur.
    @ObservationIgnored public var ghosttyBackgroundBlur: (@MainActor () -> Int)?
    /// Called just before `setSetting` makes a write by the person (`SettingWriter/user`: the
    /// Settings window, a user-origin action, the app's own asks, a call a native confirmation
    /// approved), with the descriptor and the value (nil: removed). It may return an undo, which
    /// runs when the file write then fails, so state recorded for the write never outlives it.
    /// A file edit, a synced cmux-next.json or a caller other than the person never calls it, so
    /// the hang reports controller records this Mac's consent from it alone.
    @ObservationIgnored public var userWillWrite: (@MainActor (SettingDescriptor, JSONValue?) -> (@MainActor () -> Void)?)?
    /// Font families written lately to a font family setting (`setSetting`), newest first.
    @ObservationIgnored public var recentFonts = RecentFonts()
    /// Device-scoped values of the managing team's policy; set with `setTeamPolicy`.
    public internal(set) var teamPolicy: TeamPolicyLayer = .none

    @ObservationIgnored let applier: SettingsApplier
    /// The design settings this controller applies to (`DesignSettings.shared` in the app).
    public var design: DesignSettings { applier.design }
    @ObservationIgnored private var diagnosticToasts: SettingsDiagnosticToasts?
    @ObservationIgnored private var watcher: ConfigFileWatcher?
    /// The app's main-thread scheduler: watcher events, a reload's landing and a cancelled waiter's resume
    /// reach main as `visible` tasks on it.
    @ObservationIgnored let mainWork: MainWorkScheduler
    /// A reload reads off main now; a request made meanwhile reads again once it landed.
    @ObservationIgnored private var reloading = false
    @ObservationIgnored private var reloadRequested = false
    @ObservationIgnored private var lastSource: LoadInputs?
    @ObservationIgnored let managedReader: any ManagedPreferenceReader
    @ObservationIgnored let managedWatchFiles: [URL]
    @ObservationIgnored var managedWatchers: [ConfigFileWatcher] = []
    @ObservationIgnored var statusTarget: ManagedStatusTarget?
    @ObservationIgnored var lastStatusBody: JSONValue?
    /// The app activation backstop's subscription (`followActivation(on:)`).
    @ObservationIgnored var activation: EventSubscription?
    @ObservationIgnored private var loadWaiters: [LoadWaiter] = []
    /// The launch's read (`startLaunchRead`), adopted by the first load; until then it is the managed layer launch steps read.
    @ObservationIgnored var launchRead: LaunchRead?
    /// Writes `setSetting` validated and made, by dotted key (tests check
    /// that palette actions write through it).
    @ObservationIgnored var validatedWrites: [String: Int] = [:]

    private struct LoadWaiter {
        let token: UUID
        let count: Int
        let continuation: OnceContinuation<Void, OnceContinuationError>
    }

    /// Everything a load depends on; an unchanged input skips the apply.
    nonisolated struct LoadInputs: Equatable, Sendable {
        let source: String
        let managed: ManagedPreferences
        let team: TeamPolicyLayer
    }

    public init(
        registry: ActionRegistry,
        design: DesignSettings = .shared,
        fileURL: URL = CmuxConfigFile.defaultURL(),
        managedReader: any ManagedPreferenceReader = ManagedPreferenceLocation.defaultReader(),
        managedWatchFiles: [URL] = ManagedPreferenceLocation.watchedFiles(),
        launch: LaunchRead? = nil,
        mainWork: MainWorkScheduler = MainWorkScheduler(budget: MainFrameBudget())
    ) {
        self.file = CmuxConfigFile(url: fileURL)
        self.launchRead = launch
        self.applier = SettingsApplier(design: design, registry: registry)
        self.managedReader = managedReader
        self.managedWatchFiles = managedWatchFiles
        self.mainWork = mainWork
    }

    /// Applies the launch's read as the first load, on the calling thread, with no file call and no
    /// watch, so the first window draws in the file's appearance while ``start(announcingDiagnostics:)``
    /// waits until after the first frame (p08-startup-079; Chrome applies the profile's read
    /// preferences before the first window and arms the file watchers later). Nothing without a
    /// launch read or after the first load.
    public func adoptLaunchRead() {
        guard loadCount == 0, let launch = launchRead else { return }
        launchRead = nil
        adopt(launch.loaded)
    }

    /// Loads the file now (the launch's read when the controller was made with one: no file call
    /// on this thread) and starts watching it; the watches are armed off this thread, then reload
    /// once. After ``adoptLaunchRead()`` it only arms the watches and reloads once off this
    /// thread, so an edit made since the launch read applies. `announcingDiagnostics`: the app
    /// also tells the person about a value it ignores (`SettingsDiagnosticToasts`) through this
    /// presenter, sending them to its Settings row only while `availability` says the page draws
    /// it; tests leave the presenter nil.
    public func start(announcingDiagnostics presenter: (any SettingsDiagnosticPresenting)? = nil,
                      availability: @escaping @MainActor () -> SettingsAvailability = { SettingsAvailability() }) {
        guard watcher == nil else { return }
        let watcher = ConfigFileWatcher(url: file.url) { [weak self, mainWork] in
            mainWork.postFromAnyThread(.visible, owner: "Settings.fileChanged") { [weak self] in self?.requestReload() }
        }
        self.watcher = watcher
        watcher.startWithoutWaiting()
        startManagedWatchers()
        if loadCount == 0 { loadNow() } else { requestReload() }
        if let presenter, diagnosticToasts == nil {
            // After the first load: the toasts' first read is the loaded file, never the empty state before it.
            let toasts = SettingsDiagnosticToasts(registry: applier.registry, presenter: presenter,
                                                  availability: availability)
            diagnosticToasts = toasts
            toasts.follow(self)
        }
    }

    public func stop() {
        watcher?.stop()
        watcher = nil
        stopManagedWatchers()
        reloadRequested = false
    }

    /// Reloads now and waits until the load has applied.
    public func reload() async {
        let target = loadCount + 1
        lastSource = nil
        requestReload()
        await waitForLoad(atLeast: target)
    }

    /// Suspends until at least `count` loads have completed, or the task
    /// is cancelled.
    public func waitForLoad(atLeast count: Int) async {
        // A cancelled caller returns without registering a waiter or
        // spawning the cancellation hop below.
        guard loadCount < count, !Task.isCancelled else { return }
        let token = UUID(), mainWork = mainWork
        await withTaskCancellationHandler {
            // A dropped waiter returns as a loaded or cancelled one does.
            _ = try? await withOnceContinuation { (continuation: OnceContinuation<Void, OnceContinuationError>) in
                if Task.isCancelled || loadCount >= count {
                    continuation.resume(returning: ())
                } else {
                    loadWaiters.append(LoadWaiter(token: token, count: count, continuation: continuation))
                }
            }
        } onCancel: {
            mainWork.postFromAnyThread(.visible, owner: "Settings.waiterCancelled") { [weak self] in self?.resumeWaiter(token) }
        }
    }

    private func resumeWaiter(_ token: UUID) {
        guard let index = loadWaiters.firstIndex(where: { $0.token == token }) else { return }
        loadWaiters.remove(at: index).continuation.resume(returning: ())
    }

    // MARK: - Writing

    /// Writes `value` at a dotted or array key path. The watcher applies it.
    public func set(_ value: JSONValue, at path: [String]) async throws {
        try await file.set(value, at: path)
        // Atomic replacement can race the vnode event on the old inode. The
        // writer already knows the newest source exists, so drive the same
        // reload path and wait for it to apply even when that event is
        // coalesced away.
        await reloadAfterWrite()
    }

    /// Writes a shortcut override for `id`; nil unbinds it.
    public func setShortcut(_ shortcut: Shortcut?, for id: ActionID) async throws {
        let value: JSONValue = shortcut.map { .string(ShortcutBindingFormat.configString(SettingsApplier.stroke(for: $0))) } ?? .null
        try await set(value, at: ["shortcuts", "bindings", id.rawValue])
    }

    /// Removes the override for `id`, restoring its default shortcut.
    public func resetShortcut(for id: ActionID) async throws {
        try await file.remove(["shortcuts", "bindings", id.rawValue])
        try await file.remove(["shortcuts", id.rawValue])
        await reloadAfterWrite()
    }

    /// Writes `browser.defaultEngine` through `setSetting`.
    public func setBrowserDefaultEngine(_ engine: BrowserDefaultEngine) async throws {
        try await setSetting(at: BrowserDefaultEngine.configPath, to: .string(engine.rawValue), by: .currentRun())
    }

    /// Writes `browser.showBookmarksBar` through `setSetting`; off removes
    /// the key (the default).
    public func setShowBookmarksBar(_ show: Bool) async throws {
        try await setSetting(at: BookmarksBarSetting.configPath, to: show ? .bool(true) : nil, by: .currentRun())
    }

    /// Writes `browser.hibernation` ("off", "moderate", "aggressive" or
    /// minutes) through `setSetting`.
    public func setBrowserHibernation(_ mode: BrowserHibernationSetting.Mode) async throws {
        try await setSetting(at: BrowserHibernationSetting.configPath, to: BrowserHibernationSetting(mode: mode).configValue, by: .currentRun())
    }

    /// Writes `browser.hibernationExclusions` with `host` added ("Never Hibernate This Site")
    /// through `setSetting`; does nothing when an exclusion already matches it. Returns the
    /// setting with the host added.
    @discardableResult
    public func addBrowserHibernationExclusion(host: String) async throws -> BrowserHibernationSetting {
        let current = snapshot.browserHibernation
        let next = current.addingExclusion(host: host)
        guard next != current else { return current }
        try await setSetting(at: BrowserHibernationSetting.exclusionsPath, to: .array(next.exclusions.map(JSONValue.string)), by: .currentRun())
        return next
    }

    /// Writes `browser.keepNeighborTabsAwake` (0...3) through `setSetting`;
    /// the default (1) removes the key.
    public func setKeepNeighborTabsAwake(_ radius: Int) async throws {
        let value: JSONValue? = radius == BrowserHibernationSetting.defaultNeighborRadius ? nil : .number(Double(radius))
        try await setSetting(at: BrowserHibernationSetting.neighborRadiusPath, to: value, by: .currentRun())
    }

    /// Writes `ui.animationSpeed` through `setSetting`.
    public func setAnimationSpeed(_ speed: MotionSpeed) async throws {
        try await setSetting(at: AnimationSpeedSetting.configPath, to: .string(speed.rawValue), by: .currentRun())
    }

    /// Writes `window.titlebar` through `setSetting`; the default
    /// ("minimal") removes the key, and the `window` object when it empties.
    public func setTitlebar(_ style: TitlebarStyle) async throws {
        try await setSetting(at: WindowTitlebarSetting.configPath, to: style == WindowTitlebarSetting.fallback ? nil : .string(style.rawValue), by: .currentRun())
    }

    /// Writes `appearance.density` through `setSetting` (the Settings
    /// window, the palette and onboarding all land here).
    public func setDensity(_ density: Density) async throws {
        try await setSetting(at: ["appearance", "density"], to: .string(density.rawValue), by: .currentRun())
    }

    // MARK: - Loading

    /// Applies a completed controller write before returning to its caller.
    /// The file watcher remains responsible for edits made by other writers.
    func reloadAfterWrite() async {
        lastSource = nil
        await loadOnce()
    }

    /// Coalesces bursts of file events into one load of the latest content: the managed layers and the
    /// file are read off main, and the load lands as one `visible` task on ``mainWork`` (Chromium's
    /// `PostTaskAndReplyWithResult`, base/task/task_runner.h). A request made while one reads reads
    /// again once that one landed.
    func requestReload() {
        reloadRequested = true
        guard !reloading else { return }
        reloadNext()
    }

    private func reloadNext() {
        reloadRequested = false
        reloading = true
        let inputs = readInputs(), mainWork = mainWork
        // task-owner: one off-main read; its load lands on main and asks for the next read there
        Task { @concurrent [weak self] in
            let loaded = await Self.read(inputs)
            mainWork.postFromAnyThread(.visible, owner: "Settings.reload") { [weak self] in self?.landReload(loaded) }
        }
    }

    private func landReload(_ loaded: Loaded) {
        adopt(loaded)
        reloading = false
        if reloadRequested { reloadNext() }
    }

    /// What one load reads off main, taken on main.
    nonisolated struct ReadInputs: Sendable {
        let file: CmuxConfigFile
        let reader: any ManagedPreferenceReader
        let team: TeamPolicyLayer
        let lastGood: JSONValue
        let densities: Set<String>
        let metrics: Set<String>
    }

    private func readInputs() -> ReadInputs {
        let valid = Self.validValues
        return ReadInputs(file: file, reader: managedReader, team: teamPolicy, lastGood: fileRoot,
                          densities: valid.densities, metrics: valid.metrics)
    }

    /// The managed layers and the file's text, parsed and merged: the off-main half of a load.
    @concurrent nonisolated static func read(_ inputs: ReadInputs) async -> Loaded {
        let managed = inputs.reader.read()
        let source: Result<String, any Error>
        do { source = .success(try await inputs.file.source()) } catch { source = .failure(error) }
        return loaded(source, managed: managed, team: inputs.team, lastGood: inputs.lastGood,
                      valid: (inputs.densities, inputs.metrics), configDirectory: inputs.file.url.deletingLastPathComponent())
    }

    private func loadOnce() async {
        let inputs = readInputs()
        adopt(await Self.read(inputs))
    }

    /// The launch's first load, on the calling thread: the first window
    /// draws in the file's appearance, never a frame of the defaults first.
    private func loadNow() {
        if let launch = launchRead {
            launchRead = nil
            return adopt(launch.loaded)
        }
        let source = Result { try CmuxConfigFile.source(at: file.url) }
        adopt(Self.loaded(source, managed: managedReader.read(), team: teamPolicy, lastGood: fileRoot, valid: Self.validValues,
                          configDirectory: file.url.deletingLastPathComponent()))
    }

    typealias Loaded = (inputs: LoadInputs, effective: EffectiveSettings, snapshot: CmuxConfigSnapshot)
    static var validValues: (densities: Set<String>, metrics: Set<String>) {
        (SettingsApplier.validDensities, SettingsApplier.validMetrics)
    }

    /// Parses the file's text and merges the managed layers.
    nonisolated static func loaded(_ read: Result<String, any Error>, managed: ManagedPreferences, team: TeamPolicyLayer,
                                   lastGood: JSONValue, valid: (densities: Set<String>, metrics: Set<String>),
                                   configDirectory: URL) -> Loaded {
        var source = ""
        var problem: String?
        var root = lastGood
        do {
            source = try read.get()
            let parsed = try JSONC.parse(source)
            if case .object = parsed { root = parsed } else { problem = "root is not an object" }
        } catch {
            problem = String(describing: error)
        }
        // Managed layers always merge, over the last good file when this one
        // is unreadable, so MDM forced values apply even while the user's
        // file is broken (spec/enterprise.md 5.2).
        let effective = EffectiveSettings.merge(file: root, managed: managed, team: team)
        var snapshot = CmuxConfigSnapshot.parse(
            effective.root, validDensities: valid.densities, validMetrics: valid.metrics, configDirectory: configDirectory
        )
        if let problem { snapshot.diagnostics.insert(SettingsDiagnostic(kind: .unreadableFile, path: "", message: problem), at: 0) }
        snapshot.diagnostics += effective.diagnostics
        return (LoadInputs(source: source, managed: managed, team: team), effective, snapshot)
    }

    private func adopt(_ loaded: Loaded) {
        if loaded.inputs != lastSource || loadCount == 0 {
            lastSource = loaded.inputs
            // A file change ends a preview: the loaded values apply.
            previewingKey = nil
            previewSnapshot = nil
            diagnostics = applier.apply(loaded.snapshot)
            let effective = loaded.effective
            snapshot = loaded.snapshot
            fileRoot = effective.fileRoot
            managedKeys = effective.managedKeys
            managedChatRoots = effective.managedChatRoots
            managedPolicy = effective.policy
            let policy = ManagedPreferences.disabledFeatures(in: effective.policy)
            applier.registry.disabledFeatures = policy.features
            if let problem = policy.problem { diagnostics.append(problem) }
            file.managedGuard.update(effective.managedKeys)
            reportManagedStatus(managed: loaded.inputs.managed, team: loaded.inputs.team, effective: effective)
        }
        loadCount += 1
        let ready = loadWaiters.filter { $0.count <= loadCount }
        loadWaiters.removeAll { $0.count <= loadCount }
        ready.forEach { $0.continuation.resume(returning: ()) }
    }
}
