public import CmuxNextActions
public import CmuxNextDesign
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
    /// Number of completed loads; tests and the App can await changes by it.
    public private(set) var loadCount = 0
    /// Keys an MDM profile or the team policy manages (dotted key -> manager).
    public private(set) var managedKeys: [String: ManagedSource] = [:]
    /// Managed policy keys that are not settings (`EnrollmentToken`, `DisabledFeatures`, ...).
    public private(set) var managedPolicy: [String: JSONValue] = [:]
    /// The user's own cmux-next.json document; `snapshot.root` is the effective one.
    public private(set) var fileRoot: JSONValue = .object([:])
    /// Device-scoped values of the managing team's policy; set with `setTeamPolicy`.
    public internal(set) var teamPolicy: TeamPolicyLayer = .none

    @ObservationIgnored let applier: SettingsApplier
    @ObservationIgnored private var watcher: ConfigFileWatcher?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadRequested = false
    @ObservationIgnored private var lastSource: LoadInputs?
    @ObservationIgnored let managedReader: any ManagedPreferenceReader
    @ObservationIgnored let managedWatchFiles: [URL]
    @ObservationIgnored var managedWatchers: [ConfigFileWatcher] = []
    @ObservationIgnored var statusTarget: (url: URL, context: ManagedStatusReport.Context)?
    @ObservationIgnored var lastStatusBody: JSONValue?
    @ObservationIgnored private var loadWaiters: [LoadWaiter] = []
    /// Writes `setSetting` validated and made, by dotted key (tests check
    /// that palette actions write through it).
    @ObservationIgnored var validatedWrites: [String: Int] = [:]

    private struct LoadWaiter {
        let token: UUID
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    /// Everything a load depends on; an unchanged input skips the apply.
    private struct LoadInputs: Equatable {
        let source: String
        let managed: ManagedPreferences
        let team: TeamPolicyLayer
    }

    public init(
        registry: ActionRegistry,
        design: DesignSettings = .shared,
        fileURL: URL = CmuxConfigFile.defaultURL(),
        managedReader: any ManagedPreferenceReader = ManagedPreferenceLocation.defaultReader(),
        managedWatchFiles: [URL] = ManagedPreferenceLocation.watchedFiles()
    ) {
        self.file = CmuxConfigFile(url: fileURL)
        self.applier = SettingsApplier(design: design, registry: registry)
        self.managedReader = managedReader
        self.managedWatchFiles = managedWatchFiles
    }

    /// Loads the file now and starts watching it.
    public func start() {
        guard watcher == nil else { return }
        let watcher = ConfigFileWatcher(url: file.url) { [weak self] in
            Task { @MainActor in self?.requestReload() }
        }
        self.watcher = watcher
        watcher.start()
        startManagedWatchers()
        requestReload()
    }

    public func stop() {
        watcher?.stop()
        watcher = nil
        stopManagedWatchers()
        reloadTask?.cancel()
        reloadTask = nil
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
        guard loadCount < count else { return }
        let token = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || loadCount >= count {
                    continuation.resume()
                } else {
                    loadWaiters.append(LoadWaiter(token: token, count: count, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeWaiter(token) }
        }
    }

    private func resumeWaiter(_ token: UUID) {
        guard let index = loadWaiters.firstIndex(where: { $0.token == token }) else { return }
        loadWaiters.remove(at: index).continuation.resume()
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
        try await setSetting(at: BrowserDefaultEngine.configPath, to: .string(engine.rawValue))
    }

    /// Writes `browser.showBookmarksBar` through `setSetting`; off removes
    /// the key (the default).
    public func setShowBookmarksBar(_ show: Bool) async throws {
        try await setSetting(at: BookmarksBarSetting.configPath, to: show ? .bool(true) : nil)
    }

    /// Writes `browser.hibernation` ("off", "moderate", "aggressive" or
    /// minutes) through `setSetting`.
    public func setBrowserHibernation(_ mode: BrowserHibernationSetting.Mode) async throws {
        try await setSetting(at: BrowserHibernationSetting.configPath, to: BrowserHibernationSetting(mode: mode).configValue)
    }

    /// Writes `ui.animationSpeed` through `setSetting`.
    public func setAnimationSpeed(_ speed: MotionSpeed) async throws {
        try await setSetting(at: AnimationSpeedSetting.configPath, to: .string(speed.rawValue))
    }

    /// Writes `window.titlebar` through `setSetting`; the default
    /// ("minimal") removes the key, and the `window` object when it empties.
    public func setTitlebar(_ style: TitlebarStyle) async throws {
        try await setSetting(at: WindowTitlebarSetting.configPath, to: style == WindowTitlebarSetting.fallback ? nil : .string(style.rawValue))
    }

    /// Writes `appearance.density` through `setSetting` (the Settings
    /// window, the palette and onboarding all land here).
    public func setDensity(_ density: Density) async throws {
        try await setSetting(at: ["appearance", "density"], to: .string(density.rawValue))
    }

    /// Writes `layout.panePadding` in points; nil removes it (density default).
    public func setPanePadding(_ points: Double?) async throws {
        try await setSetting(at: ["layout", "panePadding"], to: points.map(JSONValue.number))
    }

    /// Writes `layout.paneCornerRadius` in points; nil removes it.
    public func setPaneCornerRadius(_ points: Double?) async throws {
        try await setSetting(at: ["layout", "paneCornerRadius"], to: points.map(JSONValue.number))
    }

    /// Writes `layout.paneBorder`; nil removes it (subtle).
    public func setPaneBorder(_ border: PaneBorderStyle?) async throws {
        try await setSetting(at: ["layout", "paneBorder"], to: border.map { .string($0.rawValue) })
    }

    /// Writes `layout.paneBorderWidth` in points; nil removes it (one device pixel).
    public func setPaneBorderWidth(_ points: Double?) async throws {
        try await setSetting(at: ["layout", "paneBorderWidth"], to: points.map(JSONValue.number))
    }

    /// Removes `layout.paneBorderColor` (the theme's color) or writes "#RRGGBB[AA]".
    /// Like every typed setter, it goes through `setSetting`, so a removal
    /// takes an emptied `layout` object with it and a bad value is refused.
    public func setPaneBorderColor(_ hex: String?) async throws {
        try await setSetting(at: ["layout", "paneBorderColor"], to: hex.map(JSONValue.string))
    }

    // MARK: - Loading

    /// Applies a completed controller write before returning to its caller.
    /// The file watcher remains responsible for edits made by other writers.
    func reloadAfterWrite() async {
        lastSource = nil
        await loadOnce()
    }

    /// Coalesces bursts of file events into one load of the latest content.
    func requestReload() {
        reloadRequested = true
        guard reloadTask == nil else { return }
        reloadTask = Task { [weak self] in
            while let self, self.reloadRequested {
                self.reloadRequested = false
                await self.loadOnce()
            }
            self?.reloadTask = nil
        }
    }

    private func loadOnce() async {
        let file = self.file
        let validDensities = SettingsApplier.validDensities
        let validMetrics = SettingsApplier.validMetrics
        let configDirectory = file.url.deletingLastPathComponent()
        let reader = managedReader
        let team = teamPolicy
        let lastGood = fileRoot
        let loaded: (inputs: LoadInputs, effective: EffectiveSettings, snapshot: CmuxConfigSnapshot) = await Task.detached {
            let managed = reader.read()
            var source = ""
            var problem: String?
            var root = lastGood
            do {
                source = try await file.source()
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
                effective.root, validDensities: validDensities, validMetrics: validMetrics, configDirectory: configDirectory
            )
            if let problem { snapshot.diagnostics.insert(SettingsDiagnostic(kind: .unreadableFile, path: "", message: problem), at: 0) }
            snapshot.diagnostics += effective.diagnostics
            return (LoadInputs(source: source, managed: managed, team: team), effective, snapshot)
        }.value
        if loaded.inputs != lastSource || loadCount == 0 {
            lastSource = loaded.inputs
            diagnostics = applier.apply(loaded.snapshot)
            let effective = loaded.effective
            snapshot = loaded.snapshot
            fileRoot = effective.fileRoot
            managedKeys = effective.managedKeys
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
        ready.forEach { $0.continuation.resume() }
    }
}
