public import AppKit
public import CmuxNextProcessEnvironment
import CmuxNextWakeups
import GhosttyNextKit
import os
import Synchronization

/// Process-wide libghostty app (`ghostty_app_t`) plus the user's Ghostty
/// configuration.
///
/// cmux defers fonts, colors, cursor, padding, and keybinds to the user's
/// Ghostty config, so this loads the same files Ghostty.app loads
/// (`ghostty_config_load_default_files` + `ghostty_config_load_recursive_files`,
/// ghostty.h:1318-1319). Every `ghostty_*` call stays inside this module so a
/// GhosttyKit bump touches one target (plans/cmux-next/shell.md 2.3).
///
/// Created lazily; the first access to ``shared`` runs `ghostty_init`.
public final class GhosttyRuntime {
    public static let shared = GhosttyRuntime()

    /// Nil when libghostty failed to initialize; surfaces then stay blank.
    private(set) var app: ghostty_app_t?

    /// The finalized configuration currently applied to the app.
    private(set) var config: ghostty_config_t?
    /// `background-opacity` from the user's config with cmux.json's
    /// `appearance.backgroundOpacity` over it (not the surface override).
    private var configuredBackgroundOpacity: Double = 1

    /// The user's config with one theme applied, per theme name, built on
    /// demand (`themeConfig(named:)`) and dropped on every config change.
    var themeConfigs: [String: GhosttyThemeConfig] = [:]
    /// Bumps on every config change (reload, conditional theme switch).
    public private(set) var configGeneration = 0

    /// The light/dark scheme last given to Ghostty (the app's appearance).
    public private(set) var isDark = false
    /// Live surfaces, which get every scheme change.
    let colorSchemeSurfaces = NSHashTable<TerminalSurfaceView>.weakObjects()
    /// Set while `reloadConfig` waits for Ghostty to apply the new config.
    var adoptedDuringReload = false

    /// Messages from the last config load (unknown keys, bad values).
    public private(set) var configDiagnostics: [String] = []

    /// Frontend-level actions that have no surface target (for example
    /// `quit` or `new_window` from an app-scoped keybind). Return true when
    /// handled.
    public var appActionHandler: ((TerminalHostAction) -> Bool)?

    /// Fires after a config reload so hosts can re-read derived values such
    /// as ``backgroundColor``.
    public var onConfigChange: (() -> Void)?
    /// Posted on the main actor after every config change, for views that
    /// derive geometry from it (`TerminalHostView`).
    public static let configDidChange = Notification.Name("cmux.ghostty.configDidChange")

    static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "terminal")

    private let context = RuntimeCallbackContext()
    let hostKeybindCache = HostKeybindCache()
    private var observers: [any NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?

    private init() {
        var phase = ContinuousClock.now
        func mark(_ name: String) {
            let now = ContinuousClock.now
            TerminalTimings.runtimePhase(name, phase.duration(to: now))
            phase = now
        }
        // The app froze the environment in main after preparing it; a
        // process that skips main (tests) prepares it here. Either way no
        // write may follow ghostty_init.
        let environmentGuard = ProcessEnvironmentGuard.process
        if !environmentGuard.isFrozen { Self.prepareProcessEnvironment(environmentGuard: environmentGuard) }
        environmentGuard.freeze()
        defer { mark("app_new") }
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == 0 else {
            Self.logger.error("ghostty_init failed; terminal surfaces are disabled")
            return
        }
        mark("ghostty_init")
        guard let config = Self.loadConfig(diagnostics: &configDiagnostics, opacity: &configuredBackgroundOpacity) else { return }
        mark("config_load")
        self.config = config
        // Callbacks reach the runtime through this context, never through
        // `shared`: Ghostty can call back synchronously while `shared` is
        // still being initialized (for example set_color_scheme emits
        // CONFIG_CHANGE), and re-entering a lazy static traps.
        context.runtime = self

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(context).toOpaque()
        runtime.supports_selection_clipboard = true
        runtime.wakeup_cb = ghosttyWakeup
        runtime.action_cb = ghosttyAction
        runtime.read_clipboard_cb = ghosttyReadClipboard
        runtime.confirm_read_clipboard_cb = ghosttyConfirmReadClipboard
        runtime.write_clipboard_cb = ghosttyWriteClipboard
        runtime.close_surface_cb = ghosttyCloseSurface
        app = ghostty_app_new(&runtime, config)
        guard let app else {
            Self.logger.error("ghostty_app_new failed; terminal surfaces are disabled")
            return
        }
        ghostty_app_set_focus(app, NSApp?.isActive ?? false)
        installObservers()
    }

    // MARK: Config

    /// Reloads the user's Ghostty config and pushes it to every surface
    /// (`ghostty_app_update_config`, ghostty.h:1339).
    public func reloadConfig() {
        guard let app else { return }
        var diagnostics: [String] = []
        var opacity: Double = 1
        guard let fresh = Self.loadConfig(diagnostics: &diagnostics, opacity: &opacity) else { return }
        configuredBackgroundOpacity = opacity
        adoptedDuringReload = false
        ghostty_app_update_config(app, fresh)
        // Ghostty answers with CONFIG_CHANGE on this thread: the config it
        // applied carries the light/dark variant, `fresh` does not (it
        // would put a dark app's chrome back on the light variant).
        if adoptedDuringReload { ghostty_config_free(fresh) } else { replaceConfig(fresh) }
        configDiagnostics = diagnostics
    }

    /// Adopts a config Ghostty already applied (`GHOSTTY_ACTION_CONFIG_CHANGE`).
    func adoptAppliedConfig(_ applied: ghostty_config_t) {
        adoptedDuringReload = true
        replaceConfig(ghostty_config_clone(applied))
    }

    private func replaceConfig(_ fresh: ghostty_config_t?) {
        if let config { ghostty_config_free(config) }
        config = fresh
        hostKeybindCache.binds = nil
        // Themed configs were built on the old files; rebuild on demand.
        themeConfigs.removeAll()
        configGeneration += 1
        onConfigChange?()
        NotificationCenter.default.post(name: Self.configDidChange, object: self)
    }

    /// Test hook: when set, only this file (plus its `config-file` includes)
    /// is loaded instead of the user's default Ghostty config files, so
    /// visual checks can run a tagged build under another theme.
    static let configOverrideKey = "CMUX_NEXT_GHOSTTY_CONFIG"

    /// cmux's own theme (`appearance.theme` in cmux.json, a Ghostty theme
    /// name or `light:A,dark:B`), loaded after the Ghostty config files so
    /// it replaces their `theme`. Colors the config sets explicitly still
    /// win, as in Ghostty. Nil keeps the config's theme. Set it, then call
    /// `reloadConfig()`.
    public static var themeOverride: String?

    /// `theme = <value>` for a well-formed theme spec; nil for anything
    /// that could inject another config line.
    nonisolated static func themeOverrideLine(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty, value.count <= 200,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0 != "#" && $0 != "=" && $0 != "\"" })
        else { return nil }
        return "theme = \(value)"
    }

    /// Loads the user's config. `theme` replaces `themeOverride` (a room,
    /// workspace or terminal theme; see `themeConfig(named:)`).
    static func loadConfig(diagnostics: inout [String], opacity: inout Double, theme: String? = nil) -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        // cmux's terminal padding, theme and keybinds, before the user's
        // files so theirs win.
        loadPaddingDefault(into: config)
        loadThemeDefault(into: config)
        loadKeybindDefaults(into: config)
        if let path = ProcessInfo.processInfo.environment[configOverrideKey], !path.isEmpty {
            ghostty_config_load_file(config, path)
        } else {
            ghostty_config_load_default_files(config)
        }
        ghostty_config_load_recursive_files(config)
        if let line = themeOverrideLine(theme ?? themeOverride) {
            ghostty_config_load_string(config, line, UInt(line.utf8.count), "cmux.json")
        }
        for line in fontOverrideLines(fontOverride) {
            line.withCString { ghostty_config_load_string(config, $0, UInt(line.utf8.count), "cmux.json") }
        }
        // cmux.json's window background replaces the files' opacity and
        // blur, so the surfaces, the window and the theme read one value.
        var configured: Double = 1
        _ = configGet(config, &configured, key: "background-opacity")
        var configuredBlur: Int16 = 0
        _ = configGet(config, &configuredBlur, key: "background-blur")
        for line in backgroundOverrideLines(backgroundOverride, configuredOpacity: configured, configuredBlur: Int(configuredBlur)) {
            line.withCString { ghostty_config_load_string(config, $0, UInt(line.utf8.count), "cmux.json") }
        }
        // In a translucent window the root view's material and tint are the
        // one translucent sheet; the surfaces draw cells over it with a
        // transparent default background (`GhosttyRuntimeSurfacePolicy`).
        // The resolved opacity is kept for the window and theme.
        _ = configGet(config, &configured, key: "background-opacity")
        var opacityCells = false
        _ = configGet(config, &opacityCells, key: "background-opacity-cells")
        opacity = min(max(configured, 0), 1)
        if let line = GhosttyRuntimeSurfacePolicy.override(configuredOpacity: opacity, opacityCells: opacityCells,
                                                           ownerPaintsBackground: Self.terminalBackgroundOverridden) {
            line.withCString { ghostty_config_load_string(config, $0, UInt(line.utf8.count), "cmux-next") }
        }
        ghostty_config_finalize(config)
        let count = ghostty_config_diagnostics_count(config)
        for index in 0..<count {
            let diagnostic = ghostty_config_get_diagnostic(config, index)
            if let message = diagnostic.message {
                let text = String(cString: message)
                diagnostics.append(text)
                logger.warning("ghostty config: \(text, privacy: .public)")
            }
        }
        return config
    }

    /// What a view behind a surface paints (padding, placeholder while a
    /// surface swaps): the config background when opaque, nothing in a
    /// translucent window, where the window root paints the one sheet.
    public var backgroundColor: NSColor {
        var color = ghostty_config_color_s()
        guard let config, Self.configGet(config, &color, key: "background") else {
            return .black
        }
        guard backgroundOpacity >= 1 else { return .clear }
        return NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
    }

    /// The copy-mode cursor box color: `cursor-color` when set, else the
    /// configured foreground (Ghostty colors, never a fixed accent).
    var copyCursorColor: NSColor {
        var color = ghostty_config_color_s()
        guard let config,
              Self.configGet(config, &color, key: "cursor-color") || Self.configGet(config, &color, key: "foreground")
        else { return .textColor }
        return NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
    }

    /// `background-opacity` as configured and resolved with cmux.json's
    /// override (`backgroundOverride`), 0...1. The config applied to the
    /// surfaces may carry 0 instead (`GhosttyRuntimeSurfacePolicy`).
    public var backgroundOpacity: Double { configuredBackgroundOpacity }

    /// `ghostty_config_get` (ghostty.h:1321) for one key.
    static func configGet<T: BitwiseCopyable>(_ config: ghostty_config_t, _ value: inout T, key: String) -> Bool {
        withUnsafeMutablePointer(to: &value) { valuePointer in
            key.withCString { keyPointer in
                ghostty_config_get(config, valuePointer, keyPointer, UInt(key.utf8.count))
            }
        }
    }

    // MARK: Tick and focus

    /// Runs one libghostty app tick on the main actor after a coalesced wakeup.
    func tick() {
        context.pending.store(false, ordering: .releasing)
        guard let app else { return }
        ghostty_app_tick(app)
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            // main-proof: observer registered with queue: .main (OperationQueue.main runs on the main thread)
            MainActor.assumeIsolated { self?.setAppFocused(true) }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            // main-proof: observer registered with queue: .main (OperationQueue.main runs on the main thread)
            MainActor.assumeIsolated { self?.setAppFocused(false) }
        })
        // Ghostty caches the keyboard layout for key translation.
        observers.append(center.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            // main-proof: observer registered with queue: .main (OperationQueue.main runs on the main thread)
            MainActor.assumeIsolated {
                guard let app = self?.app else { return }
                ghostty_app_keyboard_changed(app)
            }
        })
        if let nsApp = NSApp {
            applyColorScheme(nsApp.effectiveAppearance)
            // KVO calls back on the thread that changed the value: inline on
            // main, a hop from anywhere else.
            appearanceObservation = nsApp.observe(\.effectiveAppearance, options: [.new]) { @Sendable [weak self] application, _ in
                MainDelivery().run { self?.applyColorScheme(application.effectiveAppearance) }
            }
        }
    }

    /// Forward app activation so Ghostty can dim unfocused cursors.
    public func setAppFocused(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }

    /// Drives Ghostty's light/dark conditional config
    /// (`ghostty_app_set_color_scheme`, ghostty.h:1347).
    private func applyColorScheme(_ appearance: NSAppearance) {
        guard let app else { return }
        isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ghostty_app_set_color_scheme(app, isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        // A surface copies the app's scheme only when it is created; live
        // ones need it too (as Ghostty.app does per surface view), or open
        // terminals keep the old variant while the chrome switches.
        for view in colorSchemeSurfaces.allObjects { view.applyColorScheme(dark: isDark) }
    }

    // MARK: Environment

    /// Points libghostty at themes and terminfo before `ghostty_init`. Prefers
    /// resources bundled in this app, then an inherited value, then
    /// Ghostty.app. Manual-IO surfaces spawn no shell, so shell-integration
    /// and TERM here only matter for `theme =` lookups and local debug PTYs.
    /// The app calls it in `main` (`CmuxNextApp.prepareLaunchEnvironment`) before any
    /// thread starts and the environment freeze; `init` calls it only when
    /// nothing froze the environment (tests). libghostty keeps a slice of
    /// `environ` from `ghostty_init`, so no write may follow it.
    public nonisolated static func prepareProcessEnvironment(environmentGuard: ProcessEnvironmentGuard = .process) {
        environmentGuard.write("GhosttyRuntime.prepareProcessEnvironment") {
            guard let resources = resourcesDirectory() else { return }
            if let current = getenv("GHOSTTY_RESOURCES_DIR"), String(cString: current) == resources { return }
            setenv("GHOSTTY_RESOURCES_DIR", resources, 1)
        }
    }

    /// The Ghostty resources directory (themes, shell integration; terminfo
    /// is its sibling): this app's bundled copy, then an inherited
    /// `GHOSTTY_RESOURCES_DIR`, then Ghostty.app. Nil when none has themes.
    public nonisolated static func resourcesDirectory(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let fileManager = FileManager.default
        let bundled = bundle.resourceURL?.appendingPathComponent("ghostty")
        let inherited = environment["GHOSTTY_RESOURCES_DIR"]
        let ghosttyApp = "/Applications/Ghostty.app/Contents/Resources/ghostty"
        let candidates = [bundled?.path, inherited, ghosttyApp].compactMap { $0 }
        return candidates.first { fileManager.fileExists(atPath: ($0 as NSString).appendingPathComponent("themes")) }
    }

    /// Version of the linked libghostty (`ghostty_info`), which Ghostty
    /// exports to its shells as `TERM_PROGRAM_VERSION`.
    public nonisolated static var version: String? {
        let info = ghostty_info()
        guard let pointer = info.version, info.version_len > 0 else { return nil }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: Int(info.version_len))
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Runtime-level callback userdata. Collapses bursts of `wakeup_cb` (any
/// thread) into one main-actor tick and points back at the runtime.
nonisolated final class RuntimeCallbackContext: @unchecked Sendable {
    let pending = Atomic<Bool>(false)
    @MainActor weak var runtime: GhosttyRuntime?

    static func from(_ raw: UnsafeMutableRawPointer?) -> RuntimeCallbackContext? {
        guard let raw else { return nil }
        return Unmanaged<RuntimeCallbackContext>.fromOpaque(raw).takeUnretainedValue()
    }
}

/// How the surfaces' config differs from the user's: in a translucent
/// window the surfaces draw a transparent default background, so the window
/// root's sheet (`background` at `background-opacity`) is the only layer
/// behind the cells, as the single surface layer is in Ghostty.app. With
/// `background-opacity-cells` explicit cell colors take the opacity, and a
/// 0 would erase them, so the config stays as it is. A terminal background
/// override (`appearance.surfaces.terminal`) makes the surfaces transparent
/// in an opaque window too: the terminal host paints the override behind
/// the cells (`ownerPaintsBackground`).
nonisolated enum GhosttyRuntimeSurfacePolicy {
    static func override(configuredOpacity: Double, opacityCells: Bool, ownerPaintsBackground: Bool = false) -> String? {
        (configuredOpacity < 1 || ownerPaintsBackground) && !opacityCells ? "background-opacity = 0" : nil
    }
}
