public import CmuxTerminalCore
public import GhosttyKit
internal import Foundation
#if os(macOS)
internal import CoreGraphics
#endif
#if DEBUG
internal import CMUXDebugLog
#endif

/// Mutates a freshly-created `ghostty_config_t` with cmux's layered config
/// directives during engine initialization and reload.
///
/// This drains the engine-side config-load orchestration off the `GhosttyApp`
/// god type. Each method takes a `ghostty_config_t` handle and applies one
/// layer of cmux's config policy (default appearance theme, managed terminal
/// settings, startup preview profile, conditional theme override, vsync
/// fallback, cmux-owned keybind overrides, CJK font fallback, app-support
/// config files, legacy config files). The pure config-discovery decisions
/// (which paths to scan, whether a legacy/CJK/theme override applies) come from
/// the injected ``GhosttyConfigDiscovery``; this type performs only the
/// `ghostty_config_*` C-API mutation those decisions drive.
///
/// Isolation design: every method is a synchronous transform over a caller-owned
/// `ghostty_config_t` plus filesystem reads through `FileManager`. The legacy
/// `GhosttyApp` bodies ran non-isolated on the main thread by convention (engine
/// init and reload are main-driven); the loader keeps that exact shape as a
/// plain non-isolated, non-`Sendable` class. The owning engine holds one
/// instance and forwards to it, so no isolation boundary is crossed. The single
/// piece of mutable state the legacy `loadDefaultConfigFilesWithLegacyFallback`
/// wrote (`userGhosttyShellIntegrationMode`) stays on the engine; the loader is
/// stateless apart from its injected collaborators.
public final class GhosttyConfigLoader {
    private let discovery: GhosttyConfigDiscovery

    #if DEBUG
    /// DEBUG-only init-log sink, wired by the engine to its file-backed init
    /// log so `loadLegacyGhosttyConfigIfNeeded` keeps the legacy diagnostic
    /// line. No-op in release builds (the legacy call was `#if DEBUG`-only).
    private let initLog: (String) -> Void
    #endif

    #if DEBUG
    /// Creates a loader over the given config-discovery seam and DEBUG init-log
    /// sink.
    public init(
        discovery: GhosttyConfigDiscovery,
        initLog: @escaping (String) -> Void
    ) {
        self.discovery = discovery
        self.initLog = initLog
    }
    #else
    /// Creates a loader over the given config-discovery seam.
    public init(discovery: GhosttyConfigDiscovery) {
        self.discovery = discovery
    }
    #endif

    /// Loads inline Ghostty config text into `config` under a synthetic source
    /// path, skipping empty input.
    public func loadInlineGhosttyConfig(
        _ contents: String,
        into config: ghostty_config_t,
        prefix: String,
        logLabel _: String
    ) {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let syntheticPath = "/__cmux_inline__/\(prefix).conf"
        trimmed.withCString { contents in
            syntheticPath.withCString { path in
                ghostty_config_load_string(
                    config,
                    contents,
                    UInt(trimmed.lengthOfBytes(using: .utf8)),
                    path
                )
            }
        }
    }

    /// Loads cmux's default appearance theme for `preferredColorScheme`,
    /// preferring the on-disk theme file and falling back to inline contents.
    public func loadCmuxDefaultAppearanceConfig(
        _ config: ghostty_config_t,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    ) {
        if let url = GhosttyConfig.cmuxDefaultThemeConfigURL(preferredColorScheme: preferredColorScheme) {
            url.path.withCString { path in
                ghostty_config_load_file(config, path)
            }
            return
        }

        loadInlineGhosttyConfig(
            GhosttyConfig.cmuxDefaultThemeConfigContents(preferredColorScheme: preferredColorScheme),
            into: config,
            prefix: "cmux-default-appearance",
            logLabel: "default appearance fallback"
        )
    }

    /// Loads the cmux-managed terminal settings layer (resolved app-side and
    /// passed in as `contents`), skipping when there is nothing to apply.
    public func loadCmuxManagedTerminalSettingsConfig(
        _ config: ghostty_config_t,
        contents: String?
    ) {
        guard let contents else { return }
        loadInlineGhosttyConfig(
            contents,
            into: config,
            prefix: "cmux-managed-terminal-settings",
            logLabel: "managed terminal settings"
        )
    }

    /// Loads a DEBUG startup-appearance preview `profile` into `config`,
    /// delegating to the default-appearance loader for `.freshInstall`.
    public func loadStartupPreviewProfile(
        _ profile: GhosttyStartupAppearancePreviewProfile,
        into config: ghostty_config_t,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    ) {
        if profile == .freshInstall {
            loadCmuxDefaultAppearanceConfig(
                config,
                preferredColorScheme: preferredColorScheme
            )
            return
        }

        guard let contents = profile.previewConfigContents(
            preferredColorScheme: preferredColorScheme
        ) else { return }
        loadInlineGhosttyConfig(
            contents,
            into: config,
            prefix: "cmux-startup-preview",
            logLabel: "startup appearance preview"
        )
    }

    /// Loads a conditional theme override for `preferredColorScheme` when the
    /// config-discovery seam decides one applies.
    public func loadConditionalThemeOverrideIfNeeded(
        _ config: ghostty_config_t,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    ) {
        guard let contents = discovery.conditionalThemeOverrideConfigContents(
            preferredColorScheme: preferredColorScheme
        ) else { return }

        loadInlineGhosttyConfig(
            contents,
            into: config,
            prefix: "cmux-conditional-theme",
            logLabel: "conditional theme override"
        )
    }

    /// Disables vsync when no active display is attached, so background-only
    /// launches do not stall waiting for a display refresh.
    public func loadNoActiveDisplayVsyncFallbackIfNeeded(_ config: ghostty_config_t) {
        var displayCount: UInt32 = 0
        let error = CGGetActiveDisplayList(0, nil, &displayCount)
        guard error == .success, displayCount == 0 else { return }

        loadInlineGhosttyConfig(
            "window-vsync = false",
            into: config,
            prefix: "cmux-no-active-display-vsync-fallback",
            logLabel: "no active display vsync fallback"
        )
#if DEBUG
        logDebugEvent("ghostty.vsync.disable reason=noActiveDisplays")
#endif
    }

    /// Removes Ghostty's default split/close fallbacks so cmux's remappable
    /// shortcut layer owns those keys.
    public func loadCmuxOwnedGhosttyKeybindOverrides(_ config: ghostty_config_t) {
        // cmux owns these split and close shortcuts through KeyboardShortcutSettings.
        // Remove Ghostty's default fallbacks so remapped or cleared shortcuts
        // can reach the focused terminal instead of splitting or closing outside
        // the remappable shortcut layer.
        loadInlineGhosttyConfig(
            """
            keybind = super+d=unbind
            keybind = super+shift+d=unbind
            keybind = super+w=unbind
            keybind = super+alt+w=unbind
            keybind = super+shift+w=unbind
            \(GhosttyConfigDiscovery.numberedWorkspaceGhosttyUnbinds)
            """,
            into: config,
            prefix: "cmux-owned-keybind-overrides",
            logLabel: "cmux-owned keybind overrides"
        )
    }

    /// Injects sensible CJK font-codepoint mappings when the config-discovery
    /// seam reports the user has not already covered the affected ranges.
    ///
    /// When the user has not configured `font-codepoint-map` for CJK ranges
    /// and has not already provided an explicit multi-entry `font-family`
    /// fallback chain, Ghostty's `CTFontCollection` scoring may pick an
    /// inappropriate fallback font for Hiragana, Katakana, and CJK symbols.
    /// The scoring prioritizes monospace fonts, so decorative fonts with
    /// monospace attributes (e.g. AB_appare from Adobe CC, or LingWai) can be
    /// selected depending on what is installed. This injects a sensible
    /// default based on the system's preferred languages without overriding
    /// user-managed fallback chains or configured fonts that already cover
    /// the affected CJK ranges.
    ///
    /// See: https://github.com/manaflow-ai/cmux/pull/1017
    public func loadCJKFontFallbackIfNeeded(_ config: ghostty_config_t) {
        guard let mappings = discovery.autoInjectedCJKFontMappings() else { return }

        var resolvedFonts: [String: String] = [:]
        let lines = mappings.map { range, font in
            let resolvedFont = resolvedFonts[font] ?? {
                let resolved = discovery.resolvedInjectedCJKFontName(named: font)
                resolvedFonts[font] = resolved
                return resolved
            }()
            return "font-codepoint-map = \(range)=\(resolvedFont)"
        }.joined(separator: "\n")
        loadInlineGhosttyConfig(
            lines,
            into: config,
            prefix: "cmux-cjk-font-fallback",
            logLabel: "CJK font fallback"
        )
    }

    /// Loads cmux's app-support Ghostty config files (theme directives written
    /// by cmux's own settings UI) discovered for the current bundle.
    public func loadCmuxAppSupportGhosttyConfigIfNeeded(_ config: ghostty_config_t) {
        #if os(macOS)
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        guard let currentBundleIdentifier = Bundle.main.bundleIdentifier,
              !currentBundleIdentifier.isEmpty else { return }
        let urls = discovery.cmuxAppSupportConfigURLs(
            currentBundleIdentifier: currentBundleIdentifier,
            appSupportDirectory: appSupport,
            fileManager: fm
        )
        guard !urls.isEmpty else { return }

        for url in urls {
            url.path.withCString { path in
                ghostty_config_load_file(config, path)
            }
        }

#if DEBUG
        logDebugEvent(
            "loaded cmux app support ghostty config from: \(urls.map(\.path).joined(separator: ", "))"
        )
        #endif
        #endif
    }

    /// Returns the last `theme = ...` directive value across cmux's app-support
    /// config files, or `nil` when none is present.
    public func currentCmuxAppSupportThemeValue() -> String? {
        #if os(macOS)
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let urls = discovery.cmuxAppSupportConfigURLs(
            currentBundleIdentifier: Bundle.main.bundleIdentifier,
            appSupportDirectory: appSupport,
            fileManager: fm
        )

        var lastValue: String?
        for url in urls {
            guard let contents = try? String(contentsOf: url, encoding: .utf8),
                  let value = GhosttyConfig.lastThemeDirective(in: contents) else {
                continue
            }
            lastValue = value
        }
        return lastValue
        #else
        return nil
        #endif
    }

    /// Loads the legacy `config` file only when the preferred `config.ghostty`
    /// is absent or empty, so stale legacy files never override current config.
    public func loadLegacyGhosttyConfigIfNeeded(_ config: ghostty_config_t) {
        #if os(macOS)
        // Ghostty 1.3+ prefers `config.ghostty`, but some users still have their real
        // settings in the legacy `config` file. Use legacy only when `config.ghostty`
        // is absent or empty, so stale legacy files do not override current config.
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let ghosttyDir = appSupport.appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        let configNew = ghosttyDir.appendingPathComponent("config.ghostty", isDirectory: false)
        let configLegacy = ghosttyDir.appendingPathComponent("config", isDirectory: false)

        func fileSize(_ url: URL) -> Int? {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? NSNumber else { return nil }
            return size.intValue
        }

        guard discovery.shouldLoadLegacyGhosttyConfig(
            newConfigFileSize: fileSize(configNew),
            legacyConfigFileSize: fileSize(configLegacy)
        ) else { return }

        configLegacy.path.withCString { path in
            ghostty_config_load_file(config, path)
        }

        #if DEBUG
        initLog("loaded legacy ghostty config because config.ghostty was empty: \(configLegacy.path)")
        #endif
        #endif
    }
}
