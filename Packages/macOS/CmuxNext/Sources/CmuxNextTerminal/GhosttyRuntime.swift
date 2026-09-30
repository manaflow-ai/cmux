public import AppKit
import GhosttyKit
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

    /// Messages from the last config load (unknown keys, bad values).
    public private(set) var configDiagnostics: [String] = []

    /// Frontend-level actions that have no surface target (for example
    /// `quit` or `new_window` from an app-scoped keybind). Return true when
    /// handled.
    public var appActionHandler: ((TerminalHostAction) -> Bool)?

    /// Fires after a config reload so hosts can re-read derived values such
    /// as ``backgroundColor``.
    public var onConfigChange: (() -> Void)?

    static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "terminal")

    private let context = RuntimeCallbackContext()
    let hostKeybindCache = HostKeybindCache()
    private var observers: [any NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?

    private init() {
        Self.configureProcessEnvironment()
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == 0 else {
            Self.logger.error("ghostty_init failed; terminal surfaces are disabled")
            return
        }
        guard let config = Self.loadConfig(diagnostics: &configDiagnostics) else { return }
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
        runtime.tmux_control_cb = ghosttyTmuxControl
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
        guard let fresh = Self.loadConfig(diagnostics: &diagnostics) else { return }
        ghostty_app_update_config(app, fresh)
        replaceConfig(fresh)
        configDiagnostics = diagnostics
    }

    /// Adopts a config Ghostty already applied (`GHOSTTY_ACTION_CONFIG_CHANGE`).
    func adoptAppliedConfig(_ applied: ghostty_config_t) {
        replaceConfig(ghostty_config_clone(applied))
    }

    private func replaceConfig(_ fresh: ghostty_config_t?) {
        if let config { ghostty_config_free(config) }
        config = fresh
        hostKeybindCache.binds = nil
        onConfigChange?()
    }

    /// Test hook: when set, only this file (plus its `config-file` includes)
    /// is loaded instead of the user's default Ghostty config files, so
    /// visual checks can run a tagged build under another theme.
    static let configOverrideKey = "CMUX_NEXT_GHOSTTY_CONFIG"

    private static func loadConfig(diagnostics: inout [String]) -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        if let path = ProcessInfo.processInfo.environment[configOverrideKey], !path.isEmpty {
            ghostty_config_load_file(config, path)
        } else {
            ghostty_config_load_default_files(config)
        }
        ghostty_config_load_recursive_files(config)
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

    /// The terminal background from the config, for chrome that sits behind
    /// or around a surface (padding, placeholder while a surface swaps).
    public var backgroundColor: NSColor {
        var color = ghostty_config_color_s()
        guard let config, Self.configGet(config, &color, key: "background") else {
            return .black
        }
        return NSColor(
            srgbRed: CGFloat(color.r) / 255,
            green: CGFloat(color.g) / 255,
            blue: CGFloat(color.b) / 255,
            alpha: CGFloat(backgroundOpacity)
        )
    }

    /// `background-opacity` from the config, 0...1.
    public var backgroundOpacity: Double {
        var opacity: Double = 1
        guard let config, Self.configGet(config, &opacity, key: "background-opacity") else { return 1 }
        return min(max(opacity, 0), 1)
    }

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
            MainActor.assumeIsolated { self?.setAppFocused(true) }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setAppFocused(false) }
        })
        // Ghostty caches the keyboard layout for key translation.
        observers.append(center.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let app = self?.app else { return }
                ghostty_app_keyboard_changed(app)
            }
        })
        if let nsApp = NSApp {
            applyColorScheme(nsApp.effectiveAppearance)
            appearanceObservation = nsApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] application, _ in
                MainActor.assumeIsolated {
                    self?.applyColorScheme(application.effectiveAppearance)
                }
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
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ghostty_app_set_color_scheme(app, isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    // MARK: Environment

    /// Points libghostty at themes and terminfo before `ghostty_init`. Prefers
    /// resources bundled in this app, then an inherited value, then
    /// Ghostty.app. Manual-IO surfaces spawn no shell, so shell-integration
    /// and TERM here only matter for `theme =` lookups and local debug PTYs.
    private static func configureProcessEnvironment() {
        let fileManager = FileManager.default
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("ghostty")
        let inherited = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"]
        let ghosttyApp = "/Applications/Ghostty.app/Contents/Resources/ghostty"
        let candidates = [bundled?.path, inherited, ghosttyApp].compactMap { $0 }
        if let resources = candidates.first(where: { fileManager.fileExists(atPath: ($0 as NSString).appendingPathComponent("themes")) }) {
            setenv("GHOSTTY_RESOURCES_DIR", resources, 1)
        }
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
