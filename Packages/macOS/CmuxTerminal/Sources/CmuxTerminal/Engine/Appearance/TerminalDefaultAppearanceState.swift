public import AppKit
public import CmuxTerminalCore
public import CmuxFoundation
public import GhosttyKit
internal import Foundation

/// The terminal's resolved default-appearance/background state and its
/// scope-arbitrated resolve/apply pipeline, drained out of the `GhosttyApp` god
/// type in `GhosttyTerminalView.swift` into `CmuxTerminal`.
///
/// It owns the resolved default background/foreground/cursor/selection colors,
/// the background opacity and blur, the effective terminal color-scheme
/// preference, the update-scope arbitration state, the monotonic background
/// event counter, and the owned coalescing change-notification dispatcher. The
/// app-target `GhosttyApp` holds one instance and forwards the legacy
/// `private(set) var` property reads and the `updateDefaultBackground` /
/// `updateDefaultBackgroundFromResolvedGhosttyConfig` / `applyDefaultBackground`
/// / `resetDefaultBackgroundUpdateScope` entry points to it (see
/// `GhosttyTerminalAppearance.swift`), so every app-side call site stays
/// byte-identical. The `NSWindow` side effects (`applyBackgroundToKeyWindow`,
/// `applyWindowBlur`) stay app-side and call into this type only for the state
/// apply.
///
/// Isolation design: the legacy state was plain `var` storage on the
/// non-isolated `GhosttyApp` class, mutated only on the main thread by
/// convention (the apply path runs from `@MainActor` reload/theme/action paths,
/// and `nextBackgroundEventId()` preconditions main-thread use). This drain
/// preserves that exact non-isolated shape as a plain `final class` (not
/// `Sendable`, mirroring the sibling ``TerminalDefaultBackgroundNotificationDispatcher``
/// and ``GhosttyAppService``), so `GhosttyApp` keeps constructing and calling it
/// byte-identically with no `@MainActor` ripple onto its non-isolated callers.
/// All mutable state is touched only on the main thread, exactly as the legacy
/// code was.
public final class TerminalDefaultAppearanceState {
    private let baselineAppearanceConfig: GhosttyConfig
    private let configDiscovery: GhosttyConfigDiscovery
    private let resolveColorSchemePreference: (NSColor) -> GhosttyConfig.ColorSchemePreference
    private let isBackgroundLogEnabled: () -> Bool
    private let logBackground: (String) -> Void

    /// The resolved terminal background color.
    public private(set) var defaultBackgroundColor: NSColor = .windowBackgroundColor
    /// The resolved terminal background opacity.
    public private(set) var defaultBackgroundOpacity: Double = 1.0
    /// The resolved terminal background blur.
    public private(set) var defaultBackgroundBlur: GhosttyBackgroundBlur = .disabled
    /// The resolved terminal foreground color.
    public private(set) var defaultForegroundColor: NSColor
    /// The resolved terminal cursor color.
    public private(set) var defaultCursorColor: NSColor
    /// The resolved terminal cursor text color.
    public private(set) var defaultCursorTextColor: NSColor
    /// The resolved terminal selection background color.
    public private(set) var defaultSelectionBackground: NSColor
    /// The resolved terminal selection foreground color.
    public private(set) var defaultSelectionForeground: NSColor
    /// The terminal color-scheme preference derived from the resolved background.
    public private(set) var effectiveTerminalColorSchemePreference: GhosttyConfig.ColorSchemePreference = .dark
    private var backgroundEventCounter: UInt64 = 0
    private var defaultBackgroundUpdateScope: GhosttyDefaultBackgroundUpdateScope = .unscoped
    private var defaultBackgroundScopeSource: String = "initialize"

    private lazy var defaultBackgroundNotificationDispatcher: TerminalDefaultBackgroundNotificationDispatcher =
        // Theme chrome should track terminal theme changes in the same frame.
        // Keep coalescing semantics, but flush in the next main turn instead of waiting ~1 frame.
        TerminalDefaultBackgroundNotificationDispatcher(delay: 0, logEvent: { [weak self] message in
            guard let self, self.isBackgroundLogEnabled() else { return }
            self.logBackground(message)
        })

    /// Creates the appearance state seeded from the app's fallback appearance
    /// config baseline.
    ///
    /// - Parameters:
    ///   - baselineAppearanceConfig: The fallback `GhosttyConfig` whose colors
    ///     seed the foreground/cursor/selection defaults and back the
    ///     resolve-from-config baseline (the app passes
    ///     `GhosttyApp.fallbackAppearanceConfig`).
    ///   - configDiscovery: The config discovery used to decide whether to ignore
    ///     the native legacy baseline for unparsed appearance (the app passes
    ///     `GhosttyApp.configDiscovery`).
    ///   - resolveColorSchemePreference: Maps a resolved background color to the
    ///     effective terminal color-scheme preference (the app reads the SwiftUI
    ///     readable-color-scheme helper app-side and forwards the resolved
    ///     light/dark to
    ///     `TerminalColorSchemePreference.runtimePreference(readableSchemeIsLight:)`).
    ///   - isBackgroundLogEnabled: Whether the background debug log is active;
    ///     gates string-building before any log call exactly as the legacy
    ///     `backgroundLogEnabled` gate did.
    ///   - logBackground: The background debug log sink (the app forwards to its
    ///     `BackgroundDebugLog`).
    public init(
        baselineAppearanceConfig: GhosttyConfig,
        configDiscovery: GhosttyConfigDiscovery,
        resolveColorSchemePreference: @escaping (NSColor) -> GhosttyConfig.ColorSchemePreference,
        isBackgroundLogEnabled: @escaping () -> Bool,
        logBackground: @escaping (String) -> Void
    ) {
        self.baselineAppearanceConfig = baselineAppearanceConfig
        self.configDiscovery = configDiscovery
        self.resolveColorSchemePreference = resolveColorSchemePreference
        self.isBackgroundLogEnabled = isBackgroundLogEnabled
        self.logBackground = logBackground
        self.defaultForegroundColor = baselineAppearanceConfig.foregroundColor
        self.defaultCursorColor = baselineAppearanceConfig.cursorColor
        self.defaultCursorTextColor = baselineAppearanceConfig.cursorTextColor
        self.defaultSelectionBackground = baselineAppearanceConfig.selectionBackground
        self.defaultSelectionForeground = baselineAppearanceConfig.selectionForeground
    }

    /// Resets the default-background update scope to `.unscoped`, recording the
    /// reset source so a subsequent scoped update can re-arbitrate.
    public func resetDefaultBackgroundUpdateScope(source: String) {
        let previousScope = defaultBackgroundUpdateScope
        let previousScopeSource = defaultBackgroundScopeSource
        defaultBackgroundUpdateScope = .unscoped
        defaultBackgroundScopeSource = "reset:\(source)"
        if isBackgroundLogEnabled() {
            logBackground(
                "default background scope reset source=\(source) previousScope=\(previousScope.logLabel) previousSource=\(previousScopeSource)"
            )
        }
    }

    /// Resolves the default appearance values from `config` and applies them.
    public func updateDefaultBackground(
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
        GhosttyConfig.defaultBackgroundValues(from: config, baseline: baselineAppearanceConfig)
    }

    /// Resolves the default appearance from the on-disk Ghostty config (or the
    /// passed baseline when `useOnDiskResolvedConfig` is false) and applies it.
    public func updateDefaultBackgroundFromResolvedGhosttyConfig(
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
        let resolvedValues = GhosttyConfig.resolvedDefaultBackgroundValues(
            resolved: resolved,
            baseline: baseline,
            fallbackForUnspecified: fallbackForUnspecified
        )
        applyDefaultBackground(
            color: resolvedValues.backgroundColor,
            opacity: resolvedValues.backgroundOpacity,
            backgroundBlur: resolvedValues.backgroundBlur,
            foregroundColor: resolvedValues.foregroundColor,
            cursorColor: resolvedValues.cursorColor,
            cursorTextColor: resolvedValues.cursorTextColor,
            selectionBackground: resolvedValues.selectionBackground,
            selectionForeground: resolvedValues.selectionForeground,
            source: "\(source).resolvedGhosttyConfig",
            scope: scope,
            forceNotify: forceNotify
        )
    }

    /// Applies a resolved set of default appearance values under scope
    /// arbitration, updating the stored state and posting a coalesced change
    /// notification when an observable field changes (or `forceNotify` is set).
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
            if isBackgroundLogEnabled() {
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
        effectiveTerminalColorSchemePreference = resolveColorSchemePreference(color)
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
        if isBackgroundLogEnabled() {
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
}
