public import CmuxTerminalCore
public import GhosttyKit
public import AppKit
public import CmuxFoundation
internal import Foundation
internal import os
#if DEBUG
internal import CMUXDebugLog
#endif

/// The cold embedded-Ghostty engine runtime: owns the live `ghostty_app_t` /
/// `ghostty_config_t` handles and the config-load, appearance/color-scheme,
/// default-background, and reload orchestration drained out of the `GhosttyApp`
/// god type in `GhosttyTerminalView.swift`.
///
/// This is the orchestration tier that the first `GhosttyAppService` slice said
/// "drains here later once the `handleAction` fan-out is inverted." It carries
/// every COLD path: engine initialization, layered config loading, OS-appearance
/// theme synchronization, runtime color-scheme application, resolved
/// default-background computation + change notification, and full/soft config
/// reload. None of it runs per render frame.
///
/// The HOT paths stay in the app-target `GhosttyApp` per the latency fence: the
/// wakeup→tick coalescing loop (`scheduleTick`/`tick`/`_tickScheduled`/
/// `_tickLock`) and `handleAction`'s render/scrollbar/cell-size dispatch. Those
/// read the live `app` handle from this runtime and forward the two runtime
/// callbacks back here through ``TerminalRuntimeCallbackDispatching``.
///
/// Isolation design: this is a FAITHFUL lift of the legacy non-isolated,
/// non-`Sendable` `GhosttyApp` engine state. Its cold paths were touched only
/// from the main thread by convention (engine init and reload are main-driven;
/// off-main reload callers hopped to main via `DispatchQueue.main.sync` /
/// `performOnMain`), while the `appRegistry` resolution and the two runtime
/// callbacks (wakeup/action) run on the Ghostty I/O / runtime-callback threads.
/// To preserve that exact shape byte-for-byte (and to avoid manufacturing an
/// isolation boundary the callback threads would have to cross), the runtime
/// stays a plain non-isolated class. The scroll-lag probe's `@MainActor` methods
/// are reached through `MainActor.assumeIsolated`, exactly as the legacy god did,
/// because the probe forwarders are only invoked from main (`scrollWheel`,
/// `tick`). The `appRegistry` statics stay behind the same `NSLock`.
///
/// LATENCY/ISOLATION-UNVERIFIED: no build was run for this slice. The eventual
/// single build pass should confirm the non-isolated shape compiles under the
/// package's Swift 6 mode (the legacy app target tolerated it); if strict
/// concurrency objects to a callback-thread `@Sendable` capture, add an explicit
/// `@Sendable` on the runtime-config closures (the documented stage-3b fix), not
/// `@MainActor` on this type.
public final class GhosttyEngineRuntime {
    // MARK: Injected collaborators

    /// Pure config-discovery decisions (scan paths, legacy/CJK/theme overrides).
    private let configDiscovery: GhosttyConfigDiscovery

    /// Engine-side `ghostty_config_t` mutation for every cmux config layer.
    private let configLoader: GhosttyConfigLoader

    /// The terminal bell + read-only config accessors leaf service.
    private let appService: GhosttyAppService

    /// Coalesces resolved-default-background change notifications.
    private let defaultBackgroundNotificationDispatcher: TerminalDefaultBackgroundNotificationDispatcher

    /// Background/theme/OSC debug log.
    private let backgroundDebugLog: BackgroundDebugLog

    /// Scroll-lag telemetry probe (the report sink submits through ``host``).
    private let scrollLagProbe: ScrollLagProbe

    /// App-coupled policy reads + window-chrome effects this slice cannot move.
    private weak var host: (any TerminalEngineRuntimeHosting)?

    /// App-side config-store reload + post-reload surface refresh.
    private weak var reloadHost: (any ConfigReloadHosting)?

    /// The hot-path / app-coupled runtime-callback owner (the god).
    private let callbackDispatcher: any TerminalRuntimeCallbackDispatching

    /// Baseline appearance values for unspecified-directive fallbacks.
    private let fallbackAppearanceConfig: GhosttyConfig

    private let initializationLogger: Logger

    // MARK: Live engine handles

    /// The live runtime app handle, or nil before engine initialization.
    public private(set) var app: ghostty_app_t?

    /// The live runtime config handle, or nil before the first config load.
    public private(set) var config: ghostty_config_t?

    // MARK: Cold engine/appearance/background state

    public private(set) var defaultBackgroundColor: NSColor = .windowBackgroundColor
    public private(set) var defaultBackgroundOpacity: Double = 1.0
    public private(set) var defaultBackgroundBlur: GhosttyBackgroundBlur = .disabled
    public private(set) var defaultForegroundColor: NSColor
    public private(set) var defaultCursorColor: NSColor
    public private(set) var defaultCursorTextColor: NSColor
    public private(set) var defaultSelectionBackground: NSColor
    public private(set) var defaultSelectionForeground: NSColor
    public private(set) var effectiveTerminalColorSchemePreference: GhosttyConfig.ColorSchemePreference = .dark
    private var appliedGhosttyRuntimeColorScheme: ghostty_color_scheme_e?
    private var runtimeColorSchemeSynchronizationDepth = 0
    private var reloadConfigurationDepth = 0
    public private(set) var usesHostLayerBackground = false
    public private(set) var userGhosttyShellIntegrationMode: String = "detect"
    private var appObservers: [NSObjectProtocol] = []
    private var backgroundEventCounter: UInt64 = 0
    private var defaultBackgroundUpdateScope: GhosttyDefaultBackgroundUpdateScope = .unscoped
    private var defaultBackgroundScopeSource: String = "initialize"
    private var lastAppearanceColorScheme: GhosttyConfig.ColorSchemePreference?

    /// Whether background logging is enabled.
    public var backgroundLogEnabled: Bool { backgroundDebugLog.isEnabled }

    // MARK: appRegistry (resolved from runtime-callback threads)

    // SAFETY: Ghostty C callbacks can run while the runtime is still
    // initializing. cmux owns one process-lifetime engine, so the registry
    // avoids singleton re-entry without adding a teardown path for a
    // ghostty_app_t that is never freed/recreated. The lock guards the two
    // static dictionaries read from the I/O / runtime-callback threads, exactly
    // as the legacy GhosttyApp.appRegistryLock did.
    private static let appRegistryLock = NSLock()
    nonisolated(unsafe) private static var appRegistry: [UInt: GhosttyEngineRuntime] = [:]
    nonisolated(unsafe) private static var initializingRuntime: GhosttyEngineRuntime?

    /// Resolves the runtime for a `userdata` pointer (was
    /// `GhosttyApp.runtimeApp(from:)`).
    public static func runtime(
        from userdata: UnsafeMutableRawPointer?
    ) -> GhosttyEngineRuntime? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttyEngineRuntime>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// Resolves the runtime for a live `app` handle (was
    /// `GhosttyApp.runtimeApp(for:)`).
    public static func runtime(for app: ghostty_app_t?) -> GhosttyEngineRuntime? {
        guard let app else { return nil }
        let key = UInt(bitPattern: app)
        appRegistryLock.lock()
        defer { appRegistryLock.unlock() }
        return appRegistry[key]
    }

    /// Resolves the runtime for the action callback, falling back to the
    /// in-flight initializing runtime (was
    /// `GhosttyApp.runtimeAppForActionCallback(_:)`).
    public static func runtimeForActionCallback(
        _ app: ghostty_app_t?
    ) -> GhosttyEngineRuntime? {
        appRegistryLock.lock()
        defer { appRegistryLock.unlock() }
        if let app {
            let key = UInt(bitPattern: app)
            if let registered = appRegistry[key] {
                return registered
            }
        }
        return initializingRuntime
    }

    private static func registerRuntime(_ runtime: GhosttyEngineRuntime, for app: ghostty_app_t) {
        let key = UInt(bitPattern: app)
        appRegistryLock.lock()
        appRegistry[key] = runtime
        appRegistryLock.unlock()
    }

    private static func setInitializingRuntime(_ runtime: GhosttyEngineRuntime?) {
        appRegistryLock.lock()
        initializingRuntime = runtime
        appRegistryLock.unlock()
    }

    // MARK: Init

    /// Creates the engine runtime over its injected collaborators and seams.
    ///
    /// `releaseBundleIdentifier` seeds the initialization `Logger` subsystem
    /// (was the private `GhosttyApp.releaseBundleIdentifier` constant).
    public init(
        configDiscovery: GhosttyConfigDiscovery,
        configLoader: GhosttyConfigLoader,
        appService: GhosttyAppService,
        defaultBackgroundNotificationDispatcher: TerminalDefaultBackgroundNotificationDispatcher,
        backgroundDebugLog: BackgroundDebugLog,
        scrollLagProbe: ScrollLagProbe,
        callbackDispatcher: any TerminalRuntimeCallbackDispatching,
        fallbackAppearanceConfig: GhosttyConfig,
        releaseBundleIdentifier: String,
        host: (any TerminalEngineRuntimeHosting)?,
        reloadHost: (any ConfigReloadHosting)?
    ) {
        self.configDiscovery = configDiscovery
        self.configLoader = configLoader
        self.appService = appService
        self.defaultBackgroundNotificationDispatcher = defaultBackgroundNotificationDispatcher
        self.backgroundDebugLog = backgroundDebugLog
        self.scrollLagProbe = scrollLagProbe
        self.callbackDispatcher = callbackDispatcher
        self.fallbackAppearanceConfig = fallbackAppearanceConfig
        self.host = host
        self.reloadHost = reloadHost
        self.defaultForegroundColor = fallbackAppearanceConfig.foregroundColor
        self.defaultCursorColor = fallbackAppearanceConfig.cursorColor
        self.defaultCursorTextColor = fallbackAppearanceConfig.cursorTextColor
        self.defaultSelectionBackground = fallbackAppearanceConfig.selectionBackground
        self.defaultSelectionForeground = fallbackAppearanceConfig.selectionForeground
        self.initializationLogger = Logger(
            subsystem: releaseBundleIdentifier,
            category: "ghostty.initialization"
        )
    }

    /// Connects the late-bound app-side seams (the app delegate conforms to both
    /// after launch).
    public func attach(
        host: any TerminalEngineRuntimeHosting,
        reloadHost: any ConfigReloadHosting
    ) {
        self.host = host
        self.reloadHost = reloadHost
    }

    // MARK: Engine initialization

    /// Initializes libghostty, loads cmux's layered config, and creates the
    /// runtime `ghostty_app_t`, falling back to a minimal config when the user
    /// config is invalid (was `GhosttyApp.initializeGhostty()`).
    @MainActor
    public func initializeGhostty() {
        // Ensure TUI apps can use colors even if NO_COLOR is set in the launcher env.
        if getenv("NO_COLOR") != nil {
            unsetenv("NO_COLOR")
        }

        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        if result != GHOSTTY_SUCCESS {
            #if DEBUG
            logDebugEvent("ghostty.initialize.failed result=\(result)")
            #endif
            reportInitializationFailure(
                "ghostty.initialize.failed",
                data: ["result": String(Int(result))]
            )
            return
        }

        guard let primaryConfig = ghostty_config_new() else {
            #if DEBUG
            logDebugEvent("ghostty.initialize.config.failed")
            #endif
            reportInitializationFailure("ghostty.initialize.config.failed")
            return
        }

        let initialColorScheme = GhosttyConfig.currentColorSchemePreference()

        let primaryRenderingModeChanged = loadDefaultConfigFilesWithLegacyFallback(
            primaryConfig,
            preferredColorScheme: initialColorScheme
        )
        updateDefaultBackground(
            from: primaryConfig,
            source: "initialize.primaryConfig",
            forceNotify: primaryRenderingModeChanged
        )
        updateDefaultBackgroundFromResolvedGhosttyConfig(
            source: "initialize.primaryConfig",
            preferredColorScheme: initialColorScheme,
            baselineConfig: primaryConfig,
            forceNotify: primaryRenderingModeChanged
        )

        var runtimeConfig = callbackDispatcher.makeRuntimeConfig()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()

        Self.setInitializingRuntime(self)
        defer { Self.setInitializingRuntime(nil) }

        if let created = ghostty_app_new(&runtimeConfig, primaryConfig) {
            self.app = created
            self.config = primaryConfig
            Self.registerRuntime(self, for: created)
        } else {
            #if DEBUG
            BackgroundDebugLog.initLog("ghostty_app_new(primary) failed; attempting fallback config")
            dumpConfigDiagnostics(primaryConfig, label: "primary")
            #endif

            ghostty_config_free(primaryConfig)

            guard let fallbackConfig = ghostty_config_new() else {
                #if DEBUG
                logDebugEvent("ghostty.initialize.fallbackConfig.failed")
                #endif
                reportInitializationFailure("ghostty.initialize.fallbackConfig.failed")
                return
            }

            loadInlineGhosttyConfig(
                "macos-background-from-layer = true",
                into: fallbackConfig,
                prefix: "cmux-renderer-bg",
                logLabel: "renderer background (fallback)"
            )
            loadInlineGhosttyConfig(
                "macos-titlebar-proxy-icon = hidden",
                into: fallbackConfig,
                prefix: "cmux-titlebar-proxy-icon",
                logLabel: "titlebar proxy icon (fallback)"
            )
            loadInlineGhosttyConfig(
                "shell-integration = none",
                into: fallbackConfig,
                prefix: "cmux-shell-integration-override",
                logLabel: "shell integration override (fallback)"
            )
            loadCmuxManagedTerminalSettingsConfig(fallbackConfig)
            loadCmuxOwnedGhosttyKeybindOverrides(fallbackConfig)
            loadNoActiveDisplayVsyncFallbackIfNeeded(fallbackConfig)
            let fallbackRenderingModeChanged = setUsesHostLayerBackground(
                true,
                source: "initialize.fallbackConfig"
            )
            ghostty_config_finalize(fallbackConfig)
            updateDefaultBackground(
                from: fallbackConfig,
                source: "initialize.fallbackConfig",
                forceNotify: fallbackRenderingModeChanged
            )
            updateDefaultBackgroundFromResolvedGhosttyConfig(
                source: "initialize.fallbackConfig",
                preferredColorScheme: initialColorScheme,
                baselineConfig: fallbackConfig,
                useOnDiskResolvedConfig: false,
                forceNotify: fallbackRenderingModeChanged
            )

            guard let created = ghostty_app_new(&runtimeConfig, fallbackConfig) else {
                #if DEBUG
                BackgroundDebugLog.initLog("ghostty_app_new(fallback) failed")
                dumpConfigDiagnostics(fallbackConfig, label: "fallback")
                logDebugEvent("ghostty.initialize.app.failed")
                #endif
                reportInitializationFailure("ghostty.initialize.app.failed")
                ghostty_config_free(fallbackConfig)
                return
            }

            self.app = created
            self.config = fallbackConfig
            Self.registerRuntime(self, for: created)
        }

        synchronizeGhosttyRuntimeColorScheme(effectiveTerminalColorSchemePreference, source: "initialize")
        lastAppearanceColorScheme = initialColorScheme
        GhosttyConfig.invalidateLoadCache()
        NotificationCenter.default.post(name: .ghosttyConfigDidReload, object: nil)

        if let app {
            // `NSApp` is `@MainActor`; engine init is main-driven, so assert it.
            let isActive = MainActor.assumeIsolated { NSApp.isActive }
            ghostty_app_set_focus(app, isActive)
        }

        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, true)
        })

        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, false)
        })

        // TODO(refactor): TerminalCopyOnSelectSettings is an app-target settings
        // type owned by another slice; the legacy init also added a
        // `TerminalCopyOnSelectSettings.didChangeNotification` observer that
        // called `reloadConfiguration(source: "settings.terminal.copyOnSelect")`.
        // Re-add that observer at the composition root (or behind a host seam)
        // when wiring this runtime, since the notification name lives in the app
        // target.
    }

    // MARK: Hot-path forwarding (handles are owned here; the loop lives in the god)

    /// The wakeup callback target (forwards to the god's tick loop). Resolved by
    /// the god's `wakeup_cb` via ``runtime(from:)``.
    public func dispatchWakeupToHost() {
        callbackDispatcher.dispatchWakeup()
    }

    /// The action callback target (forwards to the god's `handleAction`).
    /// Resolved by the god's `action_cb` via ``runtimeForActionCallback(_:)``.
    public func dispatchActionToHost(
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        callbackDispatcher.dispatchAction(target: target, action: action)
    }

    // MARK: Config-load forwarders (engine-owned, package collaborators)

    private func loadInlineGhosttyConfig(
        _ contents: String,
        into config: ghostty_config_t,
        prefix: String,
        logLabel: String
    ) {
        configLoader.loadInlineGhosttyConfig(
            contents,
            into: config,
            prefix: prefix,
            logLabel: logLabel
        )
    }

    private func loadCmuxDefaultAppearanceConfig(
        _ config: ghostty_config_t,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    ) {
        configLoader.loadCmuxDefaultAppearanceConfig(
            config,
            preferredColorScheme: preferredColorScheme
        )
    }

    @MainActor
    private func loadCmuxManagedTerminalSettingsConfig(_ config: ghostty_config_t) {
        // The host seam is `@MainActor`; this runs during main-driven engine
        // init/reload, so assert the main isolation rather than annotating the
        // non-isolated runtime (faithful to the legacy main-thread convention).
        let contents = MainActor.assumeIsolated { host?.managedTerminalSettingsConfigContents() }
        configLoader.loadCmuxManagedTerminalSettingsConfig(
            config,
            contents: contents
        )
    }

    private func loadStartupPreviewProfile(
        _ profile: GhosttyStartupAppearancePreviewProfile,
        into config: ghostty_config_t,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    ) {
        configLoader.loadStartupPreviewProfile(
            profile,
            into: config,
            preferredColorScheme: preferredColorScheme
        )
    }

    private func loadConditionalThemeOverrideIfNeeded(
        _ config: ghostty_config_t,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    ) {
        configLoader.loadConditionalThemeOverrideIfNeeded(
            config,
            preferredColorScheme: preferredColorScheme
        )
    }

    private func loadNoActiveDisplayVsyncFallbackIfNeeded(_ config: ghostty_config_t) {
        configLoader.loadNoActiveDisplayVsyncFallbackIfNeeded(config)
    }

    private func loadCmuxOwnedGhosttyKeybindOverrides(_ config: ghostty_config_t) {
        configLoader.loadCmuxOwnedGhosttyKeybindOverrides(config)
    }

    private func loadCJKFontFallbackIfNeeded(_ config: ghostty_config_t) {
        configLoader.loadCJKFontFallbackIfNeeded(config)
    }

    private func loadCmuxAppSupportGhosttyConfigIfNeeded(_ config: ghostty_config_t) {
        configLoader.loadCmuxAppSupportGhosttyConfigIfNeeded(config)
    }

    private func currentCmuxAppSupportThemeValue() -> String? {
        configLoader.currentCmuxAppSupportThemeValue()
    }

    private func loadLegacyGhosttyConfigIfNeeded(_ config: ghostty_config_t) {
        configLoader.loadLegacyGhosttyConfigIfNeeded(config)
    }

    /// Loads cmux's layered Ghostty config into `config` (was
    /// `GhosttyApp.loadDefaultConfigFilesWithLegacyFallback(...)`).
    @discardableResult
    @MainActor
    public func loadDefaultConfigFilesWithLegacyFallback(
        _ config: ghostty_config_t,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference = GhosttyConfig.currentColorSchemePreference(),
        conditionalThemeColorScheme: GhosttyConfig.ColorSchemePreference? = nil
    ) -> Bool {
        let themeColorScheme = conditionalThemeColorScheme ?? preferredColorScheme

        #if DEBUG
        let startupPreviewProfile = GhosttyStartupAppearancePreviewState.profile
        if startupPreviewProfile.loadsRealUserConfig {
            ghostty_config_load_default_files(config)
            loadLegacyGhosttyConfigIfNeeded(config)
            loadCmuxAppSupportGhosttyConfigIfNeeded(config)
            ghostty_config_load_recursive_files(config)
            loadConditionalThemeOverrideIfNeeded(
                config,
                preferredColorScheme: themeColorScheme
            )
            if configDiscovery.shouldApplyManagedDefaultAppearance() {
                loadCmuxDefaultAppearanceConfig(
                    config,
                    preferredColorScheme: preferredColorScheme
                )
            }
        } else {
            loadStartupPreviewProfile(
                startupPreviewProfile,
                into: config,
                preferredColorScheme: preferredColorScheme
            )
        }
        #else
        ghostty_config_load_default_files(config)
        loadLegacyGhosttyConfigIfNeeded(config)
        loadCmuxAppSupportGhosttyConfigIfNeeded(config)
        ghostty_config_load_recursive_files(config)
        loadConditionalThemeOverrideIfNeeded(
            config,
            preferredColorScheme: themeColorScheme
        )
        if configDiscovery.shouldApplyManagedDefaultAppearance() {
            loadCmuxDefaultAppearanceConfig(
                config,
                preferredColorScheme: preferredColorScheme
            )
        }
        #endif
        loadCJKFontFallbackIfNeeded(config)
        let renderingModeChanged = setUsesHostLayerBackground(
            true,
            source: "loadDefaultConfigFilesWithLegacyFallback"
        )
        loadInlineGhosttyConfig(
            "macos-background-from-layer = true",
            into: config,
            prefix: "cmux-renderer-bg",
            logLabel: "renderer background"
        )
        loadInlineGhosttyConfig(
            "macos-titlebar-proxy-icon = hidden",
            into: config,
            prefix: "cmux-titlebar-proxy-icon",
            logLabel: "titlebar proxy icon"
        )
        userGhosttyShellIntegrationMode = "detect"
        do {
            var value: UnsafePointer<Int8>?
            let key = "shell-integration"
            if ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))),
               let value {
                userGhosttyShellIntegrationMode = String(cString: value)
            }
        }

        loadInlineGhosttyConfig(
            "shell-integration = none",
            into: config,
            prefix: "cmux-shell-integration-override",
            logLabel: "shell integration override"
        )
        loadCmuxManagedTerminalSettingsConfig(config)
        loadCmuxOwnedGhosttyKeybindOverrides(config)
        loadNoActiveDisplayVsyncFallbackIfNeeded(config)

        ghostty_config_finalize(config)
        return renderingModeChanged
    }

    // MARK: Runtime color-scheme decisions (pure)

    public static func shouldReloadConfigurationForAppearanceChange(
        previousColorScheme: GhosttyConfig.ColorSchemePreference?,
        currentColorScheme: GhosttyConfig.ColorSchemePreference
    ) -> Bool {
        GhosttyConfig.shouldReloadConfigurationForAppearanceChange(
            previousColorScheme: previousColorScheme,
            currentColorScheme: currentColorScheme
        )
    }

    public static func ghosttyRuntimeColorScheme(
        for colorScheme: GhosttyConfig.ColorSchemePreference
    ) -> ghostty_color_scheme_e {
        GhosttyConfig.ghosttyRuntimeColorScheme(for: colorScheme)
    }

    nonisolated private func terminalRuntimeColorSchemePreference(
        forBackgroundColor backgroundColor: NSColor
    ) -> GhosttyConfig.ColorSchemePreference {
        // TODO(refactor): cmuxReadableColorScheme(for:) is an app-target
        // free helper (Sidebar/SidebarAppearanceSupport.swift) owned by another
        // slice; the host seam provides the equivalent. Legacy:
        // `cmuxReadableColorScheme(for: backgroundColor) == .light ? .light : .dark`.
        // Main-confined (called from main-driven appearance resolution).
        // `assumeIsolated` already asserts main (this method is main-confined per
        // the note above); bind self via `nonisolated(unsafe)` to suppress the
        // redundant sending-self region check for the host read.
        nonisolated(unsafe) let unsafeSelf = self
        return MainActor.assumeIsolated {
            unsafeSelf.host?.terminalColorSchemePreference(forBackgroundColor: backgroundColor)
        } ?? .dark
    }

    @MainActor
    private func runtimeColorSchemeForConfigLoad(
        source: String,
        requestedColorScheme: GhosttyConfig.ColorSchemePreference,
        effectiveTerminalColorScheme: GhosttyConfig.ColorSchemePreference,
        cmuxThemeValue: String?
    ) -> GhosttyConfig.ColorSchemePreference {
        // TODO(refactor): GhosttySurfaceConfigurationRefresh.isCmuxThemeReloadSource
        // is app-target; routed through the host seam (main-confined reload path).
        let isThemeReload = MainActor.assumeIsolated { host?.isCmuxThemeReloadSource(source) } ?? false
        guard isThemeReload,
              let cmuxThemeValue,
              GhosttyConfig.themeValueUsesSameResolvedThemeInBothColorSchemes(cmuxThemeValue) else {
            return requestedColorScheme
        }

        return effectiveTerminalColorScheme
    }

    // MARK: Reload + appearance synchronization

    /// Reloads cmux's Ghostty configuration (full or soft) and re-resolves the
    /// default background (was `GhosttyApp.reloadConfiguration(...)`).
    @MainActor
    public func reloadConfiguration(
        soft: Bool = false,
        source: String = "unspecified",
        reloadSettingsFromFile: Bool = true,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference? = nil
    ) {
        guard reloadConfigurationDepth == 0 else {
            logThemeAction("reload skipped source=\(source) soft=\(soft) reason=reentrant")
            return
        }
        reloadConfigurationDepth += 1
        defer { reloadConfigurationDepth -= 1 }

        // The reload path is main-driven by contract (legacy hopped to main for
        // the config-store reload via `MainActor.assumeIsolated`/`.sync`); the
        // `@MainActor` host/reloadHost seams are asserted on main here.
        MainActor.assumeIsolated {
            if reloadSettingsFromFile {
                host?.reloadKeyboardShortcutSettingsFromFile()
            }
            reloadHost?.reloadCmuxConfigStores(source: source)
        }
        let reloadColorScheme = preferredColorScheme ?? GhosttyConfig.currentColorSchemePreference()
        guard let app else {
            logThemeAction("reload skipped source=\(source) soft=\(soft) reason=no_app")
            return
        }
        let loadColorScheme = runtimeColorSchemeForConfigLoad(
            source: source,
            requestedColorScheme: reloadColorScheme,
            effectiveTerminalColorScheme: effectiveTerminalColorSchemePreference,
            cmuxThemeValue: currentCmuxAppSupportThemeValue()
        )
        synchronizeGhosttyRuntimeColorScheme(loadColorScheme, source: "reloadConfiguration:\(source):load")
        logThemeAction("reload begin source=\(source) soft=\(soft)")
        resetDefaultBackgroundUpdateScope(source: "reloadConfiguration(source=\(source))")
        if soft, let config {
            let effectiveReloadColorScheme = effectiveTerminalColorSchemePreference
            synchronizeGhosttyRuntimeColorScheme(effectiveReloadColorScheme, source: "reloadConfiguration:\(source):resolved")
            ghostty_app_update_config(app, config)
            lastAppearanceColorScheme = reloadColorScheme
            GhosttyConfig.invalidateLoadCache()
            NotificationCenter.default.post(name: .ghosttyConfigDidReload, object: nil)
            scheduleSurfaceRefreshAfterConfigurationReload(
                source: source,
                preferredColorScheme: effectiveReloadColorScheme
            )
            logThemeAction("reload end source=\(source) soft=\(soft) mode=soft")
            return
        }

        guard let newConfig = ghostty_config_new() else {
            logThemeAction("reload skipped source=\(source) soft=\(soft) reason=config_alloc_failed")
            return
        }
        let renderingModeChanged = loadDefaultConfigFilesWithLegacyFallback(
            newConfig,
            preferredColorScheme: reloadColorScheme
        )
        updateDefaultBackground(
            from: newConfig,
            source: "reloadConfiguration(source=\(source))",
            scope: .unscoped,
            forceNotify: renderingModeChanged
        )
        GhosttyConfig.invalidateLoadCache()
        updateDefaultBackgroundFromResolvedGhosttyConfig(
            source: "reloadConfiguration(source=\(source))",
            preferredColorScheme: reloadColorScheme,
            baselineConfig: newConfig,
            scope: .unscoped,
            forceNotify: renderingModeChanged
        )
        let effectiveReloadColorScheme = effectiveTerminalColorSchemePreference
        synchronizeGhosttyRuntimeColorScheme(effectiveReloadColorScheme, source: "reloadConfiguration:\(source):resolved")
        ghostty_app_update_config(app, newConfig)
        MainActor.assumeIsolated { host?.applyResolvedBackgroundToKeyWindow() }
        if let oldConfig = config {
            ghostty_config_free(oldConfig)
        }
        config = newConfig
        lastAppearanceColorScheme = reloadColorScheme
        NotificationCenter.default.post(name: .ghosttyConfigDidReload, object: nil)
        scheduleSurfaceRefreshAfterConfigurationReload(
            source: source,
            preferredColorScheme: effectiveReloadColorScheme
        )
        logThemeAction("reload end source=\(source) soft=\(soft) mode=full")
    }

    @MainActor
    private func scheduleSurfaceRefreshAfterConfigurationReload(
        source: String,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    ) {
        // Was `DispatchQueue.main.async { AppDelegate.shared?.refresh... }`. The
        // refresh hop is deferred to the next main turn; the `@MainActor` seam is
        // asserted inside the hop. `self` is captured weakly to mirror the legacy
        // closure that referenced the `AppDelegate.shared` global rather than the
        // engine.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.reloadHost?.refreshTerminalSurfacesAfterGhosttyConfigReload(
                    source: source,
                    preferredColorScheme: preferredColorScheme
                )
            }
        }
    }

    /// Synchronizes the terminal theme with the current OS appearance, reloading
    /// config when the color scheme changed (was
    /// `GhosttyApp.synchronizeThemeWithAppearance(_:source:)`).
    @MainActor
    public func synchronizeThemeWithAppearance(_: NSAppearance?, source: String) {
        let currentColorScheme = GhosttyConfig.currentColorSchemePreference()
        let plan = GhosttyConfig.appearanceSynchronizationPlan(
            previousColorScheme: lastAppearanceColorScheme,
            currentColorScheme: currentColorScheme
        )
        if backgroundLogEnabled {
            let previousLabel: String
            switch lastAppearanceColorScheme {
            case .light:
                previousLabel = "light"
            case .dark:
                previousLabel = "dark"
            case nil:
                previousLabel = "nil"
            }
            let currentLabel: String = currentColorScheme == .dark ? "dark" : "light"
            logBackground(
                "appearance sync source=\(source) previous=\(previousLabel) current=\(currentLabel) reload=\(plan.shouldReloadConfiguration)"
            )
        }
        guard case let .reload(colorScheme, runtimeColorScheme) = plan else { return }
        synchronizeGhosttyRuntimeColorScheme(
            runtimeColorScheme,
            colorScheme: colorScheme,
            source: source
        )
        lastAppearanceColorScheme = colorScheme
        reloadConfiguration(
            source: "appearanceSync:\(source)",
            reloadSettingsFromFile: false,
            preferredColorScheme: colorScheme
        )
    }

    /// Applies a color-scheme preference to the live `app` handle (was the
    /// one-arg `GhosttyApp.synchronizeGhosttyRuntimeColorScheme(_:source:)`).
    /// Public so the god's `handleAction` config-change cases can drive it.
    public func synchronizeGhosttyRuntimeColorScheme(
        _ colorScheme: GhosttyConfig.ColorSchemePreference,
        source: String
    ) {
        synchronizeGhosttyRuntimeColorScheme(
            Self.ghosttyRuntimeColorScheme(for: colorScheme),
            colorScheme: colorScheme,
            source: source
        )
    }

    // MARK: Scroll-lag probe forwarders (HOT readers stay in the god)
    //
    // `ScrollLagProbe`'s scroll-lag members are `@MainActor` (the state is
    // main-thread-confined). These forwarders are only invoked from the main
    // thread (`scrollWheel(with:)` and the main-queue `tick()`), so they assert
    // that isolation via `MainActor.assumeIsolated` rather than rippling
    // `@MainActor` onto this non-isolated faithful-lift type, exactly as the
    // legacy `GhosttyApp` forwarders did.

    /// Whether a scroll session is in flight (was the god's `isScrolling`).
    @MainActor
    public var isScrolling: Bool { scrollLagProbe.isScrolling }

    /// Records scroll activity (was the god's `markScrollActivity(...)`).
    @MainActor
    public func markScrollActivity(hasMomentum: Bool, momentumEnded: Bool) {
        scrollLagProbe.markScrollActivity(hasMomentum: hasMomentum, momentumEnded: momentumEnded)
    }

    /// Records a per-tick latency sample during scrolling. Called from the god's
    /// HOT `tick()` on the main queue (was `scrollLagProbe.recordTickSample`).
    @MainActor
    public func recordTickSample(elapsedMs: Double) {
        MainActor.assumeIsolated {
            scrollLagProbe.recordTickSample(elapsedMs: elapsedMs)
        }
    }

    /// Applies a runtime color scheme to the live `app` handle, deduping
    /// re-entrant requests (was the two-arg
    /// `GhosttyApp.synchronizeGhosttyRuntimeColorScheme(...)`). Public so the
    /// god's `handleAction` config/color-change cases can drive it.
    public func synchronizeGhosttyRuntimeColorScheme(
        _ runtimeColorScheme: ghostty_color_scheme_e,
        colorScheme: GhosttyConfig.ColorSchemePreference,
        source: String
    ) {
        guard let app else { return }
        let decision = GhosttyConfig.runtimeColorSchemeSynchronizationDecision(
            applied: appliedGhosttyRuntimeColorScheme,
            requested: runtimeColorScheme,
            isSynchronizing: runtimeColorSchemeSynchronizationDepth > 0
        )
        guard decision == .apply else {
            if backgroundLogEnabled {
                let schemeLabel = colorScheme == .dark ? "dark" : "light"
                let reason: String
                switch decision {
                case .apply:
                    reason = "apply"
                case .skipReentrant:
                    reason = "reentrant"
                }
                logBackground("app color scheme skipped source=\(source) scheme=\(schemeLabel) reason=\(reason)")
            }
            return
        }

        appliedGhosttyRuntimeColorScheme = runtimeColorScheme
        runtimeColorSchemeSynchronizationDepth += 1
        defer { runtimeColorSchemeSynchronizationDepth -= 1 }
        ghostty_app_set_color_scheme(app, runtimeColorScheme)
        if backgroundLogEnabled {
            let schemeLabel = colorScheme == .dark ? "dark" : "light"
            logBackground("app color scheme source=\(source) scheme=\(schemeLabel)")
        }
    }

    /// Whether a Ghostty reload action should be processed now (was
    /// `GhosttyApp.shouldProcessGhosttyReloadAction(...)`). Public so the god's
    /// `handleAction` reload cases can gate on it.
    public func shouldProcessGhosttyReloadAction(source: String, soft: Bool) -> Bool {
        guard reloadConfigurationDepth == 0,
              runtimeColorSchemeSynchronizationDepth == 0 else {
            logThemeAction("reload request skipped source=\(source) soft=\(soft) reason=reentrant")
            return false
        }
        return true
    }

    private func resetDefaultBackgroundUpdateScope(source: String) {
        let previousScope = defaultBackgroundUpdateScope
        let previousScopeSource = defaultBackgroundScopeSource
        defaultBackgroundUpdateScope = .unscoped
        defaultBackgroundScopeSource = "reset:\(source)"
        if backgroundLogEnabled {
            logBackground(
                "default background scope reset source=\(source) previousScope=\(previousScope.logLabel) previousSource=\(previousScopeSource)"
            )
        }
    }

    @discardableResult
    private func setUsesHostLayerBackground(_ newValue: Bool, source: String) -> Bool {
        let previous = usesHostLayerBackground
        usesHostLayerBackground = newValue
        let hasChanged = previous != newValue
        if hasChanged, backgroundLogEnabled {
            logBackground(
                "terminal rendering mode changed source=\(source) usesHostLayerBackground=\(newValue) previous=\(previous)"
            )
        }
        return hasChanged
    }

    // NOTE: the legacy `GhosttyApp.ghosttyColorValue(from:key:fallback:)` and
    // `defaultBackgroundBlurValue(from:)` 1:1 forwarders to
    // `GhosttyConfig.colorValue(...)` / `GhosttyConfig.backgroundBlurValue(...)`
    // had no internal callers (the resolved path uses
    // `GhosttyConfig.defaultBackgroundValues(...)` directly), so they are dropped
    // rather than relocated as dead private forwarders. Any future caller uses
    // the public `GhosttyConfig` statics directly.

    // MARK: Default-background resolution

    private func updateDefaultBackground(
        from config: ghostty_config_t?,
        source: String,
        scope: GhosttyDefaultBackgroundUpdateScope = .unscoped,
        forceNotify: Bool = false
    ) {
        guard let config else { return }

        let resolved = defaultBackgroundValues(from: config)
        applyDefaultBackground(
            color: resolved.backgroundColor,
            opacity: resolved.backgroundOpacity,
            backgroundBlur: resolved.backgroundBlur,
            foregroundColor: resolved.foregroundColor,
            cursorColor: resolved.cursorColor,
            cursorTextColor: resolved.cursorTextColor,
            selectionBackground: resolved.selectionBackground,
            selectionForeground: resolved.selectionForeground,
            source: source,
            scope: scope,
            forceNotify: forceNotify
        )
    }

    private func defaultBackgroundValues(from config: ghostty_config_t?) -> GhosttyConfig.DefaultBackgroundValues {
        GhosttyConfig.defaultBackgroundValues(from: config, baseline: fallbackAppearanceConfig)
    }

    private func resolvedAppearanceValue<T>(
        parsedValue: T,
        baselineValue: T,
        unspecifiedFallbackValue: T,
        hasParsedDirective: Bool,
        hasDirective: Bool
    ) -> T {
        GhosttyConfig.resolvedAppearanceValue(
            parsedValue: parsedValue,
            baselineValue: baselineValue,
            unspecifiedFallbackValue: unspecifiedFallbackValue,
            hasParsedDirective: hasParsedDirective,
            hasDirective: hasDirective
        )
    }

    private func updateDefaultBackgroundFromResolvedGhosttyConfig(
        source: String,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference,
        baselineConfig: ghostty_config_t?,
        scope: GhosttyDefaultBackgroundUpdateScope = .unscoped,
        useOnDiskResolvedConfig: Bool = true,
        forceNotify: Bool = false
    ) {
        let baseline = defaultBackgroundValues(from: baselineConfig)
        guard useOnDiskResolvedConfig else {
            applyDefaultBackground(
                color: baseline.backgroundColor,
                opacity: baseline.backgroundOpacity,
                backgroundBlur: baseline.backgroundBlur,
                foregroundColor: baseline.foregroundColor,
                cursorColor: baseline.cursorColor,
                cursorTextColor: baseline.cursorTextColor,
                selectionBackground: baseline.selectionBackground,
                selectionForeground: baseline.selectionForeground,
                source: source,
                scope: scope,
                forceNotify: forceNotify
            )
            return
        }
        let resolved = GhosttyConfig.load(preferredColorScheme: preferredColorScheme, useCache: false)
        let fallbackForUnspecified = configDiscovery.shouldIgnoreNativeLegacyBaselineForUnparsedAppearance()
            ? defaultBackgroundValues(from: nil)
            : baseline
        applyDefaultBackground(
            color: resolvedAppearanceValue(
                parsedValue: resolved.backgroundColor,
                baselineValue: baseline.backgroundColor,
                unspecifiedFallbackValue: fallbackForUnspecified.backgroundColor,
                hasParsedDirective: resolved.hasParsedBackgroundColor,
                hasDirective: resolved.hasBackgroundColorDirective
            ),
            opacity: resolvedAppearanceValue(
                parsedValue: resolved.backgroundOpacity,
                baselineValue: baseline.backgroundOpacity,
                unspecifiedFallbackValue: fallbackForUnspecified.backgroundOpacity,
                hasParsedDirective: resolved.hasParsedBackgroundOpacity,
                hasDirective: resolved.hasBackgroundOpacityDirective
            ),
            backgroundBlur: resolvedAppearanceValue(
                parsedValue: resolved.backgroundBlur,
                baselineValue: baseline.backgroundBlur,
                unspecifiedFallbackValue: fallbackForUnspecified.backgroundBlur,
                hasParsedDirective: resolved.hasParsedBackgroundBlur,
                hasDirective: resolved.hasBackgroundBlurDirective
            ),
            foregroundColor: resolvedAppearanceValue(
                parsedValue: resolved.foregroundColor,
                baselineValue: baseline.foregroundColor,
                unspecifiedFallbackValue: fallbackForUnspecified.foregroundColor,
                hasParsedDirective: resolved.hasParsedForegroundColor,
                hasDirective: resolved.hasForegroundColorDirective
            ),
            cursorColor: resolvedAppearanceValue(
                parsedValue: resolved.cursorColor,
                baselineValue: baseline.cursorColor,
                unspecifiedFallbackValue: fallbackForUnspecified.cursorColor,
                hasParsedDirective: resolved.hasParsedCursorColor,
                hasDirective: resolved.hasCursorColorDirective
            ),
            cursorTextColor: resolvedAppearanceValue(
                parsedValue: resolved.cursorTextColor,
                baselineValue: baseline.cursorTextColor,
                unspecifiedFallbackValue: fallbackForUnspecified.cursorTextColor,
                hasParsedDirective: resolved.hasParsedCursorTextColor,
                hasDirective: resolved.hasCursorTextColorDirective
            ),
            selectionBackground: resolvedAppearanceValue(
                parsedValue: resolved.selectionBackground,
                baselineValue: baseline.selectionBackground,
                unspecifiedFallbackValue: fallbackForUnspecified.selectionBackground,
                hasParsedDirective: resolved.hasParsedSelectionBackground,
                hasDirective: resolved.hasSelectionBackgroundDirective
            ),
            selectionForeground: resolvedAppearanceValue(
                parsedValue: resolved.selectionForeground,
                baselineValue: baseline.selectionForeground,
                unspecifiedFallbackValue: fallbackForUnspecified.selectionForeground,
                hasParsedDirective: resolved.hasParsedSelectionForeground,
                hasDirective: resolved.hasSelectionForegroundDirective
            ),
            source: "\(source).resolvedGhosttyConfig",
            scope: scope,
            forceNotify: forceNotify
        )
    }

    // MARK: Config-accessor + bell forwarders (engine leaf service)

    public func focusFollowsMouseEnabled() -> Bool {
        appService.focusFollowsMouseEnabled(config: config)
    }

    public func scrollbarVisibility() -> GhosttyConfig.ScrollbarVisibility {
        appService.scrollbarVisibility(config: config)
    }

    public func appleScriptAutomationEnabled() -> Bool {
        appService.appleScriptAutomationEnabled(config: config)
    }

    /// Rings the terminal bell from the live config (was `GhosttyApp.ringBell()`).
    /// Public so the god's `handleAction` bell cases can drive it.
    public func ringBell() {
        appService.ringBell(config: config)
    }

    /// Applies a resolved app-level color change to the default background (was
    /// `GhosttyApp.applyAppColorChange(_:source:)`). Public so the god's
    /// `handleAction` color-change case can drive it; the window-chrome reapply
    /// the legacy body did is performed by the caller through the host seam.
    public func applyAppColorChange(
        kind: ghostty_action_color_kind_e,
        newColor: NSColor,
        source: String
    ) {
        switch kind {
        case GHOSTTY_ACTION_COLOR_KIND_BACKGROUND:
            applyDefaultBackground(
                color: newColor,
                opacity: defaultBackgroundOpacity,
                backgroundBlur: defaultBackgroundBlur,
                source: source,
                scope: .app
            )
            // The window-chrome reapply for the background case is performed by
            // the caller (the god's `applyAppColorChange` → `applyBackgroundToKeyWindow`)
            // to keep a single window-apply path; the runtime owns only the
            // default-background state mutation here.
        case GHOSTTY_ACTION_COLOR_KIND_FOREGROUND:
            applyDefaultBackground(
                color: defaultBackgroundColor,
                opacity: defaultBackgroundOpacity,
                backgroundBlur: defaultBackgroundBlur,
                foregroundColor: newColor,
                source: source,
                scope: .app
            )
        case GHOSTTY_ACTION_COLOR_KIND_CURSOR:
            applyDefaultBackground(
                color: defaultBackgroundColor,
                opacity: defaultBackgroundOpacity,
                backgroundBlur: defaultBackgroundBlur,
                cursorColor: newColor,
                source: source,
                scope: .app
            )
        default:
            if backgroundLogEnabled {
                logBackground(
                    "app color change ignored color=\(newColor.hexString()) source=\(source)"
                )
            }
        }
    }

    /// Applies the resolved default-background appearance, gating by scope and
    /// notifying chrome on change (was `GhosttyApp.applyDefaultBackground(...)`).
    public func applyDefaultBackground(
        color: NSColor,
        opacity: Double,
        backgroundBlur: GhosttyBackgroundBlur,
        foregroundColor: NSColor? = nil,
        cursorColor: NSColor? = nil,
        cursorTextColor: NSColor? = nil,
        selectionBackground: NSColor? = nil,
        selectionForeground: NSColor? = nil,
        source: String,
        scope: GhosttyDefaultBackgroundUpdateScope,
        forceNotify: Bool = false
    ) {
        let previousScope = defaultBackgroundUpdateScope
        let previousScopeSource = defaultBackgroundScopeSource
        guard scope.shouldApply(over: previousScope) else {
            if backgroundLogEnabled {
                logBackground(
                    "default background skipped source=\(source) incomingScope=\(scope.logLabel) currentScope=\(previousScope.logLabel) currentSource=\(previousScopeSource) color=\(color.hexString()) opacity=\(String(format: "%.3f", opacity))"
                )
            }
            return
        }

        defaultBackgroundUpdateScope = scope
        defaultBackgroundScopeSource = source

        let previousHex = defaultBackgroundColor.hexString()
        let previousOpacity = defaultBackgroundOpacity
        let previousBlur = defaultBackgroundBlur
        let previousForegroundHex = defaultForegroundColor.hexString()
        let previousCursorHex = defaultCursorColor.hexString()
        let previousCursorTextHex = defaultCursorTextColor.hexString()
        let previousSelectionBackgroundHex = defaultSelectionBackground.hexString()
        let previousSelectionForegroundHex = defaultSelectionForeground.hexString()
        let previousColorScheme = effectiveTerminalColorSchemePreference
        defaultBackgroundColor = color
        defaultBackgroundOpacity = opacity
        defaultBackgroundBlur = backgroundBlur
        effectiveTerminalColorSchemePreference = terminalRuntimeColorSchemePreference(
            forBackgroundColor: color
        )
        if let foregroundColor {
            defaultForegroundColor = foregroundColor
        }
        if let cursorColor {
            defaultCursorColor = cursorColor
        }
        if let cursorTextColor {
            defaultCursorTextColor = cursorTextColor
        }
        if let selectionBackground {
            defaultSelectionBackground = selectionBackground
        }
        if let selectionForeground {
            defaultSelectionForeground = selectionForeground
        }
        let hasChanged = forceNotify ||
            previousHex != defaultBackgroundColor.hexString() ||
            abs(previousOpacity - defaultBackgroundOpacity) > 0.0001 ||
            previousBlur != defaultBackgroundBlur ||
            previousForegroundHex != defaultForegroundColor.hexString() ||
            previousCursorHex != defaultCursorColor.hexString() ||
            previousCursorTextHex != defaultCursorTextColor.hexString() ||
            previousSelectionBackgroundHex != defaultSelectionBackground.hexString() ||
            previousSelectionForegroundHex != defaultSelectionForeground.hexString() ||
            previousColorScheme != effectiveTerminalColorSchemePreference
        if hasChanged {
            notifyDefaultBackgroundDidChange(source: source)
        }
        if backgroundLogEnabled {
            logBackground(
                "default appearance updated source=\(source) scope=\(scope.logLabel) previousScope=\(previousScope.logLabel) previousScopeSource=\(previousScopeSource) previousBg=\(previousHex) previousFg=\(previousForegroundHex) previousOpacity=\(String(format: "%.3f", previousOpacity)) previousBlur=\(previousBlur) previousScheme=\(previousColorScheme) bg=\(defaultBackgroundColor.hexString()) fg=\(defaultForegroundColor.hexString()) cursor=\(defaultCursorColor.hexString()) cursorText=\(defaultCursorTextColor.hexString()) selectionBg=\(defaultSelectionBackground.hexString()) selectionFg=\(defaultSelectionForeground.hexString()) opacity=\(String(format: "%.3f", defaultBackgroundOpacity)) blur=\(defaultBackgroundBlur) scheme=\(effectiveTerminalColorSchemePreference) changed=\(hasChanged) forced=\(forceNotify)"
            )
        }
    }

    private func nextBackgroundEventId() -> UInt64 {
        precondition(Thread.isMainThread, "Background event IDs must be generated on main thread")
        backgroundEventCounter &+= 1
        return backgroundEventCounter
    }

    private func notifyDefaultBackgroundDidChange(source: String) {
        let signal = { [self] in
            let eventId = nextBackgroundEventId()
            defaultBackgroundNotificationDispatcher.signal(
                backgroundColor: defaultBackgroundColor,
                opacity: defaultBackgroundOpacity,
                eventId: eventId,
                source: source,
                foregroundColor: defaultForegroundColor,
                cursorColor: defaultCursorColor,
                cursorTextColor: defaultCursorTextColor,
                selectionBackground: defaultSelectionBackground,
                selectionForeground: defaultSelectionForeground
            )
        }
        if Thread.isMainThread {
            signal()
        } else {
            DispatchQueue.main.async(execute: signal)
        }
    }

    // MARK: Window blur (live app handle owned here)

    /// Applies compositor background blur to `window` for the live app (was
    /// `GhosttyApp.applyWindowBlurIfNeeded(_:)`).
    public func applyWindowBlurIfNeeded(_ window: NSWindow) {
        guard let app = self.app else { return }
        GhosttyWindowBlurInterop.applyWindowBackgroundBlur(
            app: app, windowPointer: Unmanaged.passUnretained(window).toOpaque())
    }

    // MARK: Diagnostics + logging

    #if DEBUG
    private func dumpConfigDiagnostics(_ config: ghostty_config_t, label: String) {
        let count = Int(ghostty_config_diagnostics_count(config))
        guard count > 0 else {
            BackgroundDebugLog.initLog("ghostty diagnostics (\(label)): none")
            return
        }
        BackgroundDebugLog.initLog("ghostty diagnostics (\(label)): count=\(count)")
        for i in 0..<count {
            let diag = ghostty_config_get_diagnostic(config, UInt32(i))
            let msg = diag.message.flatMap { String(cString: $0) } ?? "(null)"
            BackgroundDebugLog.initLog("  [\(i)] \(msg)")
        }
    }
    #endif

    private func reportInitializationFailure(
        _ message: String,
        data: [String: String] = [:]
    ) {
        if data.isEmpty {
            initializationLogger.error("\(message, privacy: .public)")
        } else {
            initializationLogger.error("\(message, privacy: .public) \(String(describing: data), privacy: .public)")
        }
        // Main-confined (engine init is main-driven); the `@MainActor` host seam
        // is asserted on main.
        nonisolated(unsafe) let unsafeSelf = self
        MainActor.assumeIsolated { unsafeSelf.host?.reportInitializationFailure(message, data: data) }
    }

    private func logThemeAction(_ message: String) {
        guard backgroundLogEnabled else { return }
        logBackground("theme action \(message)")
    }

    /// Appends to the background/theme/OSC debug log (was
    /// `GhosttyApp.logBackground(_:)`).
    public func logBackground(_ message: String) {
        backgroundDebugLog.log(message)
    }
}
