public import AppKit
public import CmuxNextProcessEnvironment
public import CmuxNextDesign
import CmuxNextTrace
public import CmuxNextWakeups
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
/// Created lazily, on the main actor. No config build runs there: the app
/// starts the runtime with a config built on its loader
/// (``start(loadingOn:then:)``, GhosttyRuntime+ConfigLoad.swift). Until that
/// build lands, ``app`` and ``config`` are nil, as when libghostty failed.
public final class GhosttyRuntime {
    public static let shared = GhosttyRuntime()

    /// Nil before the app starts (``start(with:)``) or when libghostty failed to initialize; surfaces then stay blank.
    /// SAFETY: set once, by `start(with:)` on the main actor, and never freed (the runtime lives
    /// for the process), so every read is a live handle or nil.
    @safe private(set) var app: ghostty_app_t?

    /// The finalized configuration currently applied to the app; nil before the app starts.
    /// SAFETY: owned here. `start(with:)` takes it over from the first GhosttyBuiltConfig, and
    /// `replaceConfig` frees the old one and stores the next (a reload's build or a clone Ghostty
    /// applied), all on the main actor like every reader; no reader keeps it past its own turn.
    @safe private(set) var config: ghostty_config_t?
    /// Whether the app was started (``start(with:)``), with or without success.
    private(set) var isStarted = false
    /// A terminal view had no surface and said so (``TerminalSurfaceView/showSurfaceUnavailable()``): logged once per process.
    var loggedSurfaceUnavailable = false
    /// Who waits for the start to end (``whenStarted(_:)``): terminal views made before it.
    private var startWaiters: [@MainActor (_ started: Bool) -> Void] = []
    /// Where config builds run (``start(loadingOn:then:)``, or a test's); nil: no reload or theme build runs.
    var configLoader: (any GhosttyConfigLoading)?
    /// `background-opacity` from the user's config with cmux.json's
    /// `appearance.backgroundOpacity` over it (not the surface override).
    var configuredBackgroundOpacity: Double = 1

    /// The user's config with one theme applied, per theme name, built on
    /// demand (`themeConfig(named:)`) and rebuilt on every config change.
    let themeConfigs = GhosttyThemeConfigCache()
    /// Counts ``reloadConfig()`` requests; only the latest one's build is applied.
    var reloadRequests = 0
    /// A ``reloadConfig()`` came before the first config landed (``start(loadingOn:then:)`` runs it then).
    var reloadAfterStart = false
    /// cmux's Kitty graphics budget per screen (``setImageStorageBytesPerScreen(_:)``), bounded from the start.
    var imageStorageBytesPerScreen = GhosttyRuntime.defaultImageStorageBytesPerScreen
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
    public internal(set) var configDiagnostics: [String] = []

    /// Frontend-level actions that have no surface target (for example `quit` or `new_window` from an
    /// app-scoped keybind). Return true when handled.
    public var appActionHandler: ((TerminalHostAction) -> Bool)?

    /// Fires after a config change so hosts can re-read derived values such as ``backgroundColor``, and
    /// after a soft reload so surfaces with their own theme take it back.
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

    nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "terminal")

    let context = RuntimeCallbackContext()
    /// The tick on the app's board and its scheduler (``attach(to:holdsHiddenActions:)``); nil before that, and in tests.
    var ticks: GhosttyTickClass?
    /// Paces the ticks to the display frame while output streams (``attach(to:holdsHiddenActions:)``); nil before that.
    var tickPacer: GhosttyTickPacer?
    /// A hidden terminal's state actions wait for it to show (``attach(to:holdsHiddenActions:)``).
    var holdsHiddenActions = false
    let hostKeybindCache = HostKeybindCache()
    /// The input sources as the terminal key path reads them (switch keys, source kind, copy mode's
    /// ASCII map); the app starts it with its runner, this runtime's observers keep it current.
    public let inputSources = TerminalInputSources()
    /// The terminals' key-to-echo stages and the process's contents gate; the app installs its input
    /// latency tracker here (``TerminalEchoStages/install(_:)``) before its first terminal.
    public let echoStages: TerminalEchoStages
    /// Splits this runtime's first surface's cost into phases; later surfaces take no split.
    let firstSurfaceSplit = TerminalFirstSurfaceSplit()
    /// Ghostty's frames into the trace ring; the app wires ``GhosttyTraceHook/connect(on:presents:)``.
    public let traceHook: GhosttyTraceHook
    /// The process's secure keyboard entry for its terminals (HIToolbox counts it per process); it holds the
    /// app trace runtime's keystroke-timing gate closed while on.
    public let secureInput = TerminalSecureInput(trace: .shared)
    private var observers: [any NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?
    /// Energy Saver's edges to libghostty (``followEnergySaver(on:)``); nil before that call, and always
    /// for a GhosttyNextKit pin without `ghostty_app_set_energy_saver`.
    private var energySaver: GhosttyEnergySaver?
    /// Puts resized terminals' drawn frames into their size's commit; nil: they land when drawn.
    public var hostFramePresenter: TerminalHostFramePresenter?

    /// Runs `ghostty_init` when `main` did not (tests); the app starts at ``start(with:)``. The app has one
    /// runtime, ``shared``; a test makes its own only to check one that never started.
    init() {
        let contentsGate = TerminalContentsGate()
        traceHook = GhosttyTraceHook(gate: contentsGate)
        echoStages = TerminalEchoStages(contentsGate: contentsGate, traceHook: traceHook)
        Self.initializeLibrary()
    }

    /// Starts libghostty's app once, with `built` (nil: the build failed); a later call frees what it was given.
    func start(with built: GhosttyBuiltConfig?) {
        guard !isStarted else {
            built?.free()
            return
        }
        isStarted = true
        // Every exit below ends the start: the views that waited for it get their surface, or learn there is none.
        defer { endStart() }
        var phase = ContinuousClock.now
        func mark(_ name: String) {
            let now = ContinuousClock.now
            TerminalTimings.runtimePhase(name, phase.duration(to: now))
            phase = now
        }
        defer { mark("app_new") }
        guard Self.initializeLibrary() else {
            Self.logger.error("ghostty_init failed; terminal surfaces are disabled")
            return
        }
        mark("ghostty_init")
        guard let built else { return }
        mark("config_load")
        recordUserConfigLoad(built)
        // SAFETY: the runtime takes over the built config (`config`'s note); nothing frees `built`
        // after this.
        config = unsafe built.config
        // Callbacks reach the runtime through this context, never through
        // `shared`: Ghostty can call back synchronously while it starts (for
        // example set_color_scheme emits CONFIG_CHANGE).
        context.runtime = self

        // `start` runs once, so the context registers once; libghostty's app is never freed, so
        // the entry stays for the process.
        guard let token = try? RuntimeCallbackContext.callbacks.register(context) else {
            Self.logger.error("no runtime callback slot; terminal surfaces are disabled")
            return
        }
        var runtime = ghostty_runtime_config_s()
        // SAFETY: the userdata is `context`'s token, never its address: a callback resolves it
        // (RuntimeCallbackContext.from), and one that comes after the context is gone finds nothing.
        unsafe runtime.userdata = token.context
        runtime.supports_selection_clipboard = true
        // SAFETY: each callback has the C signature ghostty.h declares for its slot and
        // reads its pointers only as that header documents (GhosttyRuntimeCallbacks.swift).
        unsafe runtime.wakeup_cb = ghosttyWakeup
        // SAFETY: as above.
        unsafe runtime.action_cb = ghosttyAction
        // SAFETY: as above.
        unsafe runtime.read_clipboard_cb = ghosttyReadClipboard
        // SAFETY: as above.
        unsafe runtime.confirm_read_clipboard_cb = ghosttyConfirmReadClipboard
        // SAFETY: as above.
        unsafe runtime.write_clipboard_cb = ghosttyWriteClipboard
        // SAFETY: as above.
        unsafe runtime.close_surface_cb = ghosttyCloseSurface
        // SAFETY: ghostty_app_new copies the runtime config during the call and does not take
        // over the built config, which `config` (above) now owns.
        app = TerminalTimings.ghosttyAppNew { unsafe ghostty_app_new(&runtime, config) }
        guard let app else {
            Self.logger.error("ghostty_app_new failed; terminal surfaces are disabled")
            return
        }
        // SAFETY: `app` was just created and is never freed.
        unsafe ghostty_app_set_focus(app, NSApp?.isActive ?? false)
        energySaver?.refresh()
        traceHook.refreshDemand()
        installObservers()
    }

    /// Runs `body` once the start (``start(with:)``) ended, with whether libghostty's app runs: now when it already ended,
    /// else when it ends. A terminal view made before the start (a test host, or a launch that makes a terminal before
    /// its first config build lands) makes its surface then, instead of keeping none for its life.
    func whenStarted(_ body: @escaping @MainActor (_ started: Bool) -> Void) {
        guard isStarted else { return startWaiters.append(body) }
        body(app != nil)
    }

    private func endStart() {
        let waiters = startWaiters
        startWaiters = []
        let started = app != nil
        for waiter in waiters { waiter(started) }
    }

    // MARK: Config

    /// Runs `ghostty_init` once per process; true when it succeeded. The app calls it first in `main`, after the
    /// environment freeze and before any other thread starts: ghostty_init may setenv `LANG` and call `setlocale`
    /// (Ghostty's `internal_os.ensureLocale`), which must not race another thread's `environ` read. Later calls
    /// only read the result. A process that skips `main` (tests) prepares and freezes the environment here.
    @discardableResult
    public nonisolated static func initializeLibrary() -> Bool { libraryInitialized }

    private nonisolated static let libraryInitialized: Bool = {
        let environment = ProcessEnvironmentGuard.process
        if !environment.isFrozen { GhosttyRuntime.prepareProcessEnvironment(resources: GhosttyRuntime.resourcesDirectory(), environmentGuard: environment) }
        environment.freeze()
        TerminalTimings.ghosttyInitBegan()
        defer { TerminalTimings.ghosttyInitEnded() }
        // SAFETY: unsafeArgv is the process's argv, argc entries long and valid for the
        // process's lifetime; ghostty_init only reads it.
        return unsafe ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == 0
    }()

    /// Adopts a config Ghostty already applied (`GHOSTTY_ACTION_CONFIG_CHANGE`).
    func adoptAppliedConfig(_ applied: ghostty_config_t) {
        adoptedDuringReload = true
        // SAFETY: `applied` is the config Ghostty passes to its CONFIG_CHANGE action, valid
        // for that callback; the clone is a new handle this runtime owns.
        unsafe replaceConfig(ghostty_config_clone(applied))
    }

    func replaceConfig(_ fresh: ghostty_config_t?) {
        // SAFETY: the old config is owned here and no reader keeps it past its turn
        // (`config`'s note), so it is freed once, then replaced by `fresh`, which the
        // caller hands over.
        if let config { unsafe ghostty_config_free(config) }
        // SAFETY: as above.
        config = unsafe fresh
        hostKeybindCache.binds = nil
        // Themed configs were built on the old files: each keeps serving until its rebuild lands.
        themeConfigs.invalidate(loader: configLoader) { configInputs(theme: $0) }
        onConfigChange?()
        configRevision.bump()
        for handler in configChangeHandlers { handler() }
    }

    /// Test hook: when set, only this file (plus its `config-file` includes)
    /// is loaded instead of the user's default Ghostty config files, so
    /// visual checks can run a tagged build under another theme.
    nonisolated static let configOverrideKey = "CMUX_NEXT_GHOSTTY_CONFIG"

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

    // The tick: GhosttyRuntime+Ticks.swift.

    private func installObservers() {
        let center = NotificationCenter.default // raw-observer-allow: the process's one observer of this notice for every terminal (the runtime starts before the app's AppEvents exists)
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            // main-proof: observer registered with queue: .main (OperationQueue.main runs on the main thread)
            MainActor.assumeIsolated {
                self?.setAppFocused(true)
                self?.inputSources.applicationDidBecomeActive()
            }
        }) // raw-observer-allow: the process's one observer of this notice for every terminal (the runtime starts before the app's AppEvents exists)
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            // main-proof: observer registered with queue: .main (OperationQueue.main runs on the main thread)
            MainActor.assumeIsolated { self?.setAppFocused(false) }
        })
        // raw-observer-allow: the process's one observer of this notice for every terminal (the runtime starts before the app's AppEvents exists); Ghostty caches the keyboard layout for key translation, the key path the source's kind
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
            // KVO calls back on the thread that changed the value: inline on main, a hop from anywhere else.
            // raw-observer-allow: no notice reports a light/dark switch; KVO of NSApp's effectiveAppearance is the one source, as Chromium's NativeThemeMac observes it (ui/native_theme/native_theme_mac.mm)
            appearanceObservation = nsApp.observe(\.effectiveAppearance, options: [.new]) { @Sendable [weak self] application, _ in // main-hop-allow: AppKit changes the app's appearance on main, so the scheme switch runs inline in that turn, beside ThemeResolver's re-resolve; only an off-main change hops
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

    /// Sends the Energy Saver state of `mainWork`'s policy (``MainWorkScheduler/energy``, the app's one
    /// source) to libghostty on each edge (`ghostty_app_set_energy_saver`, ghostty-next p14-energy-114):
    /// shader and Kitty animations wake at most every 33 ms and scrollback compression runs at utility
    /// QoS while it is on. ``attach(to:holdsHiddenActions:)`` calls it once. It makes no call at all when the pinned
    /// GhosttyNextKit lacks the export (`GHOSTTY_ENERGY_SAVER`, Package.swift).
    public func followEnergySaver(on mainWork: MainWorkScheduler) {
        #if GHOSTTY_ENERGY_SAVER
        let saver = GhosttyEnergySaver { [weak self] on in
            guard let app = self?.app else { return false }
            // SAFETY: `app` is live (never freed).
            unsafe ghostty_app_set_energy_saver(app, on)
            return true
        }
        energySaver = saver
        saver.follow(mainWork.energy, queue: mainWork.wakeUps)
        #endif
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
            // SAFETY: Swift passes NUL-terminated copies of both strings that live for the call;
            // setenv copies them, inside the guard's one environment write.
            unsafe setenv("GHOSTTY_RESOURCES_DIR", resources, 1)
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
