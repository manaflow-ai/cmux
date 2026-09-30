public import CmuxNextActions
public import CmuxNextDesign
public import Foundation
public import Observation

/// Loads `~/.config/cmux/cmux.json`, applies it to `DesignSettings` and the
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

    @ObservationIgnored private let applier: SettingsApplier
    @ObservationIgnored private var watcher: ConfigFileWatcher?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadRequested = false
    @ObservationIgnored private var lastSource: String?
    @ObservationIgnored private var loadWaiters: [LoadWaiter] = []

    private struct LoadWaiter {
        let token: UUID
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    public init(
        registry: ActionRegistry,
        design: DesignSettings = .shared,
        fileURL: URL = CmuxConfigFile.defaultURL()
    ) {
        self.file = CmuxConfigFile(url: fileURL)
        self.applier = SettingsApplier(design: design, registry: registry)
    }

    /// Loads the file now and starts watching it.
    public func start() {
        guard watcher == nil else { return }
        let watcher = ConfigFileWatcher(url: file.url) { [weak self] in
            Task { @MainActor in self?.requestReload() }
        }
        self.watcher = watcher
        watcher.start()
        requestReload()
    }

    public func stop() {
        watcher?.stop()
        watcher = nil
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
    }

    /// Writes a shortcut override for `id`; nil unbinds it.
    public func setShortcut(_ shortcut: Shortcut?, for id: ActionID) async throws {
        let value: JSONValue = shortcut.map { .string(ShortcutBindingFormat.configString(SettingsApplier.stroke(for: $0))) } ?? .null
        try await file.set(value, at: ["shortcuts", "bindings", id.rawValue])
    }

    /// Removes the override for `id`, restoring its default shortcut.
    public func resetShortcut(for id: ActionID) async throws {
        try await file.remove(["shortcuts", "bindings", id.rawValue])
        try await file.remove(["shortcuts", id.rawValue])
    }

    /// Writes `browser.defaultEngine`.
    public func setBrowserDefaultEngine(_ engine: BrowserDefaultEngine) async throws {
        try await file.set(.string(engine.rawValue), at: BrowserDefaultEngine.configPath)
    }

    /// Writes `ui.animationSpeed`.
    public func setAnimationSpeed(_ speed: MotionSpeed) async throws {
        try await file.set(.string(speed.rawValue), at: AnimationSpeedSetting.configPath)
    }

    /// Writes `window.titlebar`; the default ("minimal") removes the key,
    /// and the `window` object when it empties.
    public func setTitlebar(_ style: TitlebarStyle) async throws {
        guard style == WindowTitlebarSetting.fallback else {
            return try await file.set(.string(style.rawValue), at: WindowTitlebarSetting.configPath)
        }
        try await file.remove(WindowTitlebarSetting.configPath)
        if case .object(let members)? = try await file.value(at: ["window"]), members.isEmpty {
            try await file.remove(["window"])
        }
    }

    public func setDensity(_ density: Density) async throws {
        try await file.set(.string(density.rawValue), at: ["appearance", "density"])
    }

    /// Writes `layout.panePadding` in points; nil removes it (density default).
    public func setPanePadding(_ points: Double?) async throws {
        try await setLayoutValue(points.map(JSONValue.number), key: "panePadding")
    }

    /// Writes `layout.paneCornerRadius` in points; nil removes it.
    public func setPaneCornerRadius(_ points: Double?) async throws {
        try await setLayoutValue(points.map(JSONValue.number), key: "paneCornerRadius")
    }

    /// Writes `layout.paneBorder`; nil removes it (subtle).
    public func setPaneBorder(_ border: PaneBorderStyle?) async throws {
        try await setLayoutValue(border.map { .string($0.rawValue) }, key: "paneBorder")
    }

    /// Writes `layout.paneBorderWidth` in points; nil removes it (one device pixel).
    public func setPaneBorderWidth(_ points: Double?) async throws {
        try await setLayoutValue(points.map(JSONValue.number), key: "paneBorderWidth")
    }

    /// Removes `layout.paneBorderColor` (the theme's color) or writes "#RRGGBB[AA]".
    public func setPaneBorderColor(_ hex: String?) async throws {
        try await setLayoutValue(hex.map(JSONValue.string), key: "paneBorderColor")
    }

    private func setLayoutValue(_ value: JSONValue?, key: String) async throws {
        if let value {
            try await file.set(value, at: ["layout", key])
        } else {
            try await file.remove(["layout", key])
            // The last pane key going back to its default takes the empty
            // `layout` object with it.
            if case .object(let members)? = try await file.value(at: ["layout"]), members.isEmpty {
                try await file.remove(["layout"])
            }
        }
    }

    // MARK: - Loading

    /// Coalesces bursts of file events into one load of the latest content.
    private func requestReload() {
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
        let loaded: (source: String, snapshot: CmuxConfigSnapshot) = await Task.detached {
            do {
                let source = try await file.source()
                do {
                    let root = try JSONC.parse(source)
                    return (source, CmuxConfigSnapshot.parse(
                        root, validDensities: validDensities, validMetrics: validMetrics, configDirectory: configDirectory
                    ))
                } catch {
                    var snapshot = CmuxConfigSnapshot.empty
                    snapshot.diagnostics = [SettingsDiagnostic(kind: .unreadableFile, path: "", message: String(describing: error))]
                    return (source, snapshot)
                }
            } catch {
                var snapshot = CmuxConfigSnapshot.empty
                snapshot.diagnostics = [SettingsDiagnostic(kind: .unreadableFile, path: "", message: String(describing: error))]
                return ("", snapshot)
            }
        }.value
        if loaded.source != lastSource || loadCount == 0 {
            lastSource = loaded.source
            diagnostics = applier.apply(loaded.snapshot)
            if !loaded.snapshot.diagnostics.contains(where: { $0.kind == .unreadableFile }) {
                snapshot = loaded.snapshot
            }
        }
        loadCount += 1
        let ready = loadWaiters.filter { $0.count <= loadCount }
        loadWaiters.removeAll { $0.count <= loadCount }
        ready.forEach { $0.continuation.resume() }
    }
}
