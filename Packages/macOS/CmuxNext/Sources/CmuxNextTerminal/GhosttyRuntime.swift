public import AppKit
public import CmuxNextProcessEnvironment
public import CmuxNextDesign
import CmuxNextTrace
import CmuxNextWakeups
import GhosttyNextKit
import os
import CmuxNextCompat

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
    /// SAFETY: set once in `init` and never freed (the runtime lives for the
    /// process), so every read is a live handle or nil.
    @safe private(set) var app: ghostty_app_t?

    /// The finalized configuration currently applied to the app.
    /// SAFETY: owned here and freed only by `replaceConfig`, on the main actor
    /// like every reader, after which the new one is stored; no reader keeps it
    /// past its own turn.
    @safe private(set) var config: ghostty_config_t?
    /// `background-opacity` from the user's config with cmux.json's
    /// `appearance.backgroundOpacity` over it (not the surface override).
    private var configuredBackgroundOpacity: Double = 1

    /// The user's config with one theme applied, per theme name, built on
    /// demand (`themeConfig(named:)`) and dropped on every config change.
    var themeConfigs: [String: GhosttyThemeConfig] = [:]
    /// Bumps on every config change (reload, conditional theme switch), after the new config is in
    /// place. Visible views observe it; hidden ones read it when they show.
    public let configRevision = GhosttyConfigRevision()

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

    /// Fires after a config change so hosts can re-read derived values such
    /// as ``backgroundColor``, and after a soft reload so surfaces with their
    /// own theme take it back.
    public var onConfigChange: (() -> Void)?
    /// The services' handlers (``addConfigChangeHandler(_:)``), in the order added.
    private var configChangeHandlers: [@MainActor () -> Void] = []

    /// Runs `handler` after each config change, once ``configRevision`` counts it, after the
    /// handlers added before it: for services that re-read the config whether or not a terminal
    /// shows. A soft reload (`reload_config` with `soft`) changes no config and runs none.
    /// Views observe ``configRevision``.
    public func addConfigChangeHandler(_ handler: @escaping @MainActor () -> Void) {
        configChangeHandlers.append(handler)
    }

    static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "terminal")

    private let context = RuntimeCallbackContext()
    let hostKeybindCache = HostKeybindCache()
    /// The input sources as the terminal key path reads them (switch keys, source kind, copy mode's
    /// ASCII map); the app starts it with its runner, this runtime's observers keep it current.
    public let inputSources = TerminalInputSources()
    /// The terminals' key-to-echo stages and the process's contents gate; the app installs its input
    /// latency tracker here (``TerminalEchoStages/install(_:)``, p04-input-094) before its first terminal.
    public let echoStages = TerminalEchoStages(contentsGate: TerminalContentsGate())
    /// The process's secure keyboard entry for its terminals (HIToolbox counts it per process); it holds the
    /// app trace runtime's keystroke-timing gate closed while on (p09-observability-128).
    public let secureInput = TerminalSecureInput(trace: .shared)
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
        if !environmentGuard.isFrozen { Self.prepareProcessEnvironment(resources: Self.resourcesDirectory(), environmentGuard: environmentGuard) }
        environmentGuard.freeze()
        defer { mark("app_new") }
        // SAFETY: unsafeArgv is the process's argv, argc entries long and valid for the
        // process's lifetime; ghostty_init only reads it.
        guard unsafe ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == 0 else {
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
        // SAFETY: the userdata is unretained: `context` is this runtime's stored
        // constant and the runtime is never freed, so every callback that gets it back
        // (RuntimeCallbackContext.from) sees a live object.
        unsafe runtime.userdata = Unmanaged.passUnretained(context).toOpaque()
        runtime.supports_selection_clipboard = true
        // SAFETY: each callback has the C signature ghostty.h declares for its slot and
        // reads its pointers only as that header documents (GhosttyRuntimeCallbacks.swift).
        unsafe runtime.wakeup_cb = ghosttyWakeup
        unsafe runtime.action_cb = ghosttyAction
        unsafe runtime.read_clipboard_cb = ghosttyReadClipboard
        unsafe runtime.confirm_read_clipboard_cb = ghosttyConfirmReadClipboard
        unsafe runtime.write_clipboard_cb = ghosttyWriteClipboard
        unsafe runtime.close_surface_cb = ghosttyCloseSurface
        // SAFETY: ghostty_app_new copies the runtime config during the call and does not
        // take over `config`, which stays owned by this runtime.
        app = unsafe ghostty_app_new(&runtime, config)
        guard let app else {
            Self.logger.error("ghostty_app_new failed; terminal surfaces are disabled")
            return
        }
        // SAFETY: `app` was just created and is never freed.
        unsafe ghostty_app_set_focus(app, NSApp?.isActive ?? false)
        installObservers()
    }

    // MARK: Config

    /// Reloads the user's Ghostty config and pushes it to every surface
    /// (`ghostty_app_update_config`, ghostty.h:1339).
    public func reloadConfig() {
        guard let app else { return }
        var diagnostics: [String] = []
        var opacity: Double = 1
        // SAFETY: loadConfig returns a new handle that this function owns.
        guard let fresh = unsafe Self.loadConfig(diagnostics: &diagnostics, opacity: &opacity) else { return }
        configuredBackgroundOpacity = opacity
        adoptedDuringReload = false
        applyColorTransitionToSurfaces()
        // SAFETY: `app` is the live app (never freed); update_config copies what it keeps
        // from `fresh`, which this function still owns.
        unsafe ghostty_app_update_config(app, fresh)
        // Ghostty answers with CONFIG_CHANGE on this thread: the config it
        // applied carries the light/dark variant, `fresh` does not (it
        // would put a dark app's chrome back on the light variant).
        // SAFETY: `fresh` is owned here and leaves by exactly one path: freed, or moved
        // into `config`.
        if adoptedDuringReload { unsafe ghostty_config_free(fresh) } else { unsafe replaceConfig(fresh) }
        configDiagnostics = diagnostics
    }

    /// Adopts a config Ghostty already applied (`GHOSTTY_ACTION_CONFIG_CHANGE`).
    func adoptAppliedConfig(_ applied: ghostty_config_t) {
        adoptedDuringReload = true
        // SAFETY: `applied` is the config Ghostty passes to its CONFIG_CHANGE action, valid
        // for that callback; the clone is a new handle this runtime owns.
        unsafe replaceConfig(ghostty_config_clone(applied))
    }

    private func replaceConfig(_ fresh: ghostty_config_t?) {
        // SAFETY: the old config is owned here and no reader keeps it past its turn
        // (`config`'s note), so it is freed once, then replaced by `fresh`, which the
        // caller hands over.
        if let config { unsafe ghostty_config_free(config) }
        config = unsafe fresh
        hostKeybindCache.binds = nil
        // Themed configs were built on the old files; rebuild on demand.
        themeConfigs.removeAll()
        onConfigChange?()
        configRevision.bump()
        for handler in configChangeHandlers { handler() }
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

    /// `appearance.themeEdits`: per-token color edits to themes, loaded after
    /// the theme they edit (`themeLines`). Set it, then call `reloadConfig()`.
    public static var themeEdits = ThemeEdits.none

    /// The light/dark side `themeLines` takes from a pair, as the app's
    /// color scheme last was (`applyColorScheme`).
    static var colorSchemeIsDark = false

    /// The theme lines cmux loads after the user's config files: `theme =
    /// <spec>`, then the edits of the theme in effect (a pair's variant for
    /// `isDark`), so an edited token wins and the rest stay the theme's.
    /// `theme` nil is the Ghostty config's own theme, which has no name to
    /// key edits by.
    public nonisolated static func themeLines(_ theme: String?, isDark: Bool, edits: ThemeEdits) -> [String] {
        guard let line = themeOverrideLine(theme) else { return [] }
        let name = theme.flatMap(ThemeSpec.init).map { $0.name(isDark: isDark) }
        return [line] + (name.map(edits.configLines(for:)) ?? [])
    }

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
        // SAFETY: a new handle owned by this function until it returns it; every call
        // below that takes `config` gets this live handle.
        guard let config = unsafe ghostty_config_new() else { return nil }
        // cmux's defaults, before the user's files so theirs win.
        // SAFETY: `config` is the live handle from ghostty_config_new (above).
        unsafe loadPaddingDefault(into: config)
        // SAFETY: as above.
        unsafe loadThemeDefault(into: config)
        // SAFETY: as above.
        unsafe loadKeybindDefaults(into: config)
        // SAFETY: as above.
        unsafe GhosttyUnfocusedSplit.loadDefault(into: config)
        if let path = ProcessInfo.processInfo.environment[configOverrideKey], !path.isEmpty {
            // SAFETY: the live config; Swift passes a NUL-terminated copy of `path` that
            // lives for the call.
            unsafe ghostty_config_load_file(config, path)
        } else {
            // SAFETY: the live config.
            unsafe loadDefaultFiles(into: config)
        }
        // SAFETY: the live config.
        unsafe ghostty_config_load_recursive_files(config)
        for line in themeLines(theme ?? themeOverride, isDark: colorSchemeIsDark, edits: themeEdits) {
            // SAFETY: the live config.
            unsafe loadConfigLine(line, into: config, source: "cmux.json")
        }
        for line in fontOverrideLines(fontOverride) {
            // SAFETY: the live config.
            unsafe loadConfigLine(line, into: config, source: "cmux.json")
        }
        // cmux.json's window background replaces the files' opacity and
        // blur, so the surfaces, the window and the theme read one value.
        var configured: Double = 1
        // SAFETY: the live config; background-opacity is a C double.
        _ = unsafe configGet(config, &configured, key: "background-opacity")
        var configuredBlur: Int16 = 0
        // SAFETY: the live config; background-blur is an int16_t.
        _ = unsafe configGet(config, &configuredBlur, key: "background-blur")
        for line in GhosttyConfigBackground.overrideLines(configuredOpacity: configured, configuredBlur: Int(configuredBlur), theme: theme) {
            // SAFETY: the live config.
            unsafe loadConfigLine(line, into: config, source: "cmux.json")
        }
        // In a translucent window the root view's material and tint are the
        // one translucent sheet; the surfaces draw cells over it with a
        // transparent default background (`GhosttyRuntimeSurfacePolicy`).
        // The resolved opacity is kept for the window and theme.
        // SAFETY: the live config; background-opacity is a C double.
        _ = unsafe configGet(config, &configured, key: "background-opacity")
        var opacityCells = false
        // SAFETY: the live config; background-opacity-cells is a C bool.
        _ = unsafe configGet(config, &opacityCells, key: "background-opacity-cells")
        opacity = min(max(configured, 0), 1)
        seeThroughLoaded = seeThroughShown
        if let line = GhosttyRuntimeSurfacePolicy.override(configuredOpacity: opacity, opacityCells: opacityCells,
                                                           ownerPaintsBackground: Self.terminalBackgroundOverridden || Self.seeThroughShown) {
            // SAFETY: the live config.
            unsafe loadConfigLine(line, into: config, source: "cmux-next")
        }
        // SAFETY: the live config.
        unsafe ghostty_config_finalize(config)
        // SAFETY: the live config.
        unsafe loadImageStorageDefaultIfUnset(into: config)
        // SAFETY: the live config.
        let count = unsafe ghostty_config_diagnostics_count(config)
        for index in 0..<count {
            // SAFETY: `index` is below the count the same live config reported; the message
            // is a NUL-terminated string the config owns, copied by String(cString:) at once.
            let diagnostic = unsafe ghostty_config_get_diagnostic(config, index)
            if let message = unsafe diagnostic.message {
                let text = unsafe String(cString: message)
                diagnostics.append(text)
                logger.warning("ghostty config: \(text, privacy: .public)")
            }
        }
        // SAFETY: ownership of the live handle goes to the caller.
        return unsafe config
    }

    /// A new config: `load` fills it, Ghostty finalizes it, `read` reads it, then it is freed: the
    /// one owner of the configs built for defaults and tests. The handle given to the closures is
    /// live for their calls and must not leave them. Nil when Ghostty cannot make a config.
    nonisolated static func withScratchConfig<Result>(
        load: (ghostty_config_t) -> Void, read: (ghostty_config_t) -> Result
    ) -> Result? {
        // SAFETY: a new config owned here and freed once (defer), after `read` returns; the
        // closures get it only for their calls.
        guard let config = unsafe ghostty_config_new() else { return nil }
        // SAFETY: as above.
        defer { unsafe ghostty_config_free(config) }
        // SAFETY: as above.
        unsafe load(config)
        // SAFETY: as above.
        unsafe ghostty_config_finalize(config)
        // SAFETY: as above.
        return unsafe read(config)
    }

    /// Loads one config line (`ghostty_config_load_string`) into `config`, which the caller
    /// passes live, with `source` as the line's origin in Ghostty's diagnostics.
    nonisolated static func loadConfigLine(_ line: String, into config: ghostty_config_t, source: String) {
        // SAFETY: Swift passes NUL-terminated copies of `line` and `source` that live for
        // the call, and the length is `line`'s UTF-8 count without the NUL; Ghostty copies
        // what it keeps.
        unsafe ghostty_config_load_string(config, line, UInt(line.utf8.count), source)
    }

    /// What a view behind a surface paints (padding, placeholder while a
    /// surface swaps): the config background when opaque, nothing in a
    /// translucent window, where the window root paints the one sheet.
    public var backgroundColor: NSColor {
        var color = ghostty_config_color_s()
        // SAFETY: `config` is the live applied config (its note); background is a color.
        guard let config, unsafe Self.configGet(config, &color, key: "background") else {
            return .black
        }
        guard backgroundOpacity >= 1 else { return .clear }
        return NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
    }

    /// The copy-mode cursor box color: `cursor-color` when set, else the
    /// configured foreground (Ghostty colors, never a fixed accent).
    var copyCursorColor: NSColor {
        var color = ghostty_config_color_s()
        // SAFETY: `config` is the live applied config (its note); both keys read a color
        // (ghostty-next PR 34 for cursor-color).
        guard let config,
              unsafe Self.configGet(config, &color, key: "cursor-color") || Self.configGet(config, &color, key: "foreground")
        else { return .textColor }
        return NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
    }

    /// `background-opacity` as configured and resolved with cmux.json's
    /// override (`backgroundOverride`), 0...1. The config applied to the
    /// surfaces may carry 0 instead (`GhosttyRuntimeSurfacePolicy`).
    public var backgroundOpacity: Double { configuredBackgroundOpacity }

    /// `ghostty_config_get` (ghostty.h:1321) for one key.
    /// The caller passes a live config and a `T` that is the C type Ghostty writes for `key`
    /// (ghostty.h names it per key: a bool, a number, a ghostty_config_*_s struct).
    nonisolated static func configGet<T: BitwiseCopyable>(_ config: ghostty_config_t, _ value: inout T, key: String) -> Bool {
        // SAFETY: Ghostty writes one value of the key's C type, which the caller matched to
        // `T`, into `value`, which lives for the call; the key is a NUL-terminated copy Swift
        // passes for the call, its length without the NUL.
        unsafe ghostty_config_get(config, &value, key, UInt(key.utf8.count))
    }

    /// A string-valued key of a live `config` (an enum's name, a path), copied; nil when the
    /// key is unreadable or unset.
    nonisolated static func configString(_ config: ghostty_config_t, key: String) -> String? {
        var value: UnsafePointer<CChar>?
        // SAFETY: the caller's live config; a string key's C type is `const char *`, which
        // `value` is (configGet's contract).
        guard unsafe configGet(config, &value, key: key), let pointer = unsafe value else { return nil }
        // SAFETY: Ghostty's string is NUL-terminated and owned by the live config;
        // String(cString:) copies it at once.
        return unsafe String(cString: pointer)
    }

    // MARK: Tick and focus

    /// Runs one libghostty app tick on the main actor after a coalesced wakeup.
    func tick() {
        context.pending.store(false, ordering: .releasing)
        guard let app else { return }
        // SAFETY: `app` is live (never freed); a tick runs on the main actor as Ghostty asks.
        unsafe ghostty_app_tick(app)
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            // main-proof: observer registered with queue: .main (OperationQueue.main runs on the main thread)
            MainActor.assumeIsolated {
                self?.setAppFocused(true)
                self?.inputSources.applicationDidBecomeActive()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            // main-proof: observer registered with queue: .main (OperationQueue.main runs on the main thread)
            MainActor.assumeIsolated { self?.setAppFocused(false) }
        })
        // Ghostty caches the keyboard layout for key translation, the key path the source's kind.
        observers.append(center.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            // main-proof: observer registered with queue: .main (OperationQueue.main runs on the main thread)
            MainActor.assumeIsolated {
                self?.inputSources.selectedSourceChanged()
                guard let app = self?.app else { return }
                // SAFETY: `app` is live (never freed).
                unsafe ghostty_app_keyboard_changed(app)
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
        // SAFETY: `app` is live (never freed).
        unsafe ghostty_app_set_focus(app, focused)
    }

    /// Drives Ghostty's light/dark conditional config
    /// (`ghostty_app_set_color_scheme`, ghostty.h:1347).
    private func applyColorScheme(_ appearance: NSAppearance) {
        guard let app else { return }
        isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let switched = isDark != Self.colorSchemeIsDark
        Self.colorSchemeIsDark = isDark
        defer {
            // A light/dark pair's edits are its variants': the other side's need a reload.
            if switched, !Self.themeEdits.isEmpty, let spec = Self.themeOverride.flatMap(ThemeSpec.init), spec.light != spec.dark {
                reloadConfig()
            }
        }
        // SAFETY: `app` is live (never freed).
        unsafe ghostty_app_set_color_scheme(app, isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        // A surface copies the app's scheme only when it is created; live
        // ones need it too (as Ghostty.app does per surface view), or open
        // terminals keep the old variant while the chrome switches.
        for view in colorSchemeSurfaces.allObjects { view.applyColorScheme(dark: isDark) }
    }

    // MARK: Environment (the lookups: GhosttyRuntime+Environment.swift)

    /// Points libghostty at themes and terminfo before `ghostty_init`: sets
    /// `GHOSTTY_RESOURCES_DIR` to `resources` (nil leaves an inherited value).
    /// Manual-IO surfaces spawn no shell, so shell-integration and TERM here
    /// only matter for `theme =` lookups and local debug PTYs. The app calls it
    /// in `main` (`CmuxNextApp.prepareLaunchEnvironment`) with
    /// ``bundledResourcesDirectory(bundleURL:resourceURL:)``, a path with no
    /// disk call, before any thread starts and the environment freeze; `init`
    /// calls it with ``resourcesDirectory(bundle:environment:fileExists:)`` only
    /// when nothing froze the environment (tests). libghostty keeps a slice of
    /// `environ` from `ghostty_init`, so no write may follow it.
    public nonisolated static func prepareProcessEnvironment(resources: String?, environmentGuard: ProcessEnvironmentGuard = .process) {
        environmentGuard.write("GhosttyRuntime.prepareProcessEnvironment") {
            guard let resources else { return }
            // SAFETY: getenv's string is NUL-terminated and stays valid until the next
            // environment write, which only this guarded block makes, after the copy.
            if let current = unsafe getenv("GHOSTTY_RESOURCES_DIR"), unsafe String(cString: current) == resources { return }
            setenv("GHOSTTY_RESOURCES_DIR", resources, 1)
        }
    }

    /// Version of the linked libghostty (`ghostty_info`), which Ghostty
    /// exports to its shells as `TERM_PROGRAM_VERSION`.
    public nonisolated static var version: String? {
        let info = ghostty_info()
        // SAFETY: ghostty_info's version is a static string of version_len bytes in the
        // library's read-only data; String(decoding:) copies it.
        guard let pointer = unsafe info.version, info.version_len > 0 else { return nil }
        // SAFETY: as above.
        let bytes = unsafe UnsafeRawBufferPointer(start: pointer, count: Int(info.version_len))
        // SAFETY: as above.
        return unsafe String(decoding: bytes, as: UTF8.self)
    }
}

/// Runtime-level callback userdata. Collapses bursts of `wakeup_cb` (any thread, which touches
/// only the atomic flag) into one main-actor tick and points back at the runtime (main-actor only).
nonisolated final class RuntimeCallbackContext: Sendable {
    let pending = Atomic<Bool>(false)
    @MainActor weak var runtime: GhosttyRuntime?

    /// `raw` must be the runtime's userdata (`ghostty_runtime_config_s.userdata`) or nil.
    static func from(_ raw: UnsafeMutableRawPointer?) -> RuntimeCallbackContext? {
        // SAFETY: the caller passes the userdata GhosttyRuntime.init made from its context,
        // which the never-freed runtime keeps alive; taken unretained, as it was passed.
        guard let raw = unsafe raw else { return nil }
        // SAFETY: as above.
        return unsafe Unmanaged<RuntimeCallbackContext>.fromOpaque(raw).takeUnretainedValue()
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
/// the cells (`ownerPaintsBackground`). So does background art, which makes
/// a window see-through at full opacity: the host then paints only where the
/// panes do (`WindowBackdrop.panesPaintBackground`), and the art reads
/// through the window's one legible tint behind the cells.
nonisolated enum GhosttyRuntimeSurfacePolicy {
    static func override(configuredOpacity: Double, opacityCells: Bool, ownerPaintsBackground: Bool = false) -> String? {
        (configuredOpacity < 1 || ownerPaintsBackground) && !opacityCells ? "background-opacity = 0" : nil
    }
}
