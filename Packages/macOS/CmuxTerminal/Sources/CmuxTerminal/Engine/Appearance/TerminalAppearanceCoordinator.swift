public import CmuxTerminalCore
internal import GhosttyKit

/// The cold color-scheme / theme synchronization orchestrator drained out of the
/// `GhosttyApp` god type in `GhosttyTerminalView.swift` into `CmuxTerminal`.
///
/// It owns the transient synchronization state that arbitrates appearance-driven
/// ghostty runtime updates: the last applied color-scheme preference, the last
/// runtime `ghostty_color_scheme_e` pushed to libghostty, the reentrancy depth of
/// an in-flight runtime color-scheme sync, and whether the terminal currently
/// renders against a host-layer (window-owned) background. The pure fold
/// decisions (reload-required, plan, reentrancy decision, runtime mapping) live
/// as static members on ``GhosttyConfig`` in `CmuxTerminalCore`; this type
/// sequences them, mutates the owned state, and forwards the live effects
/// (`ghostty_app_set_color_scheme`, configuration reload, background log) back to
/// the app through ``TerminalAppearanceHosting``.
///
/// The app-target `GhosttyApp` holds one instance, forwards its legacy
/// `synchronizeThemeWithAppearance` / `synchronizeGhosttyRuntimeColorScheme` /
/// `shouldProcessGhosttyReloadAction` / `setUsesHostLayerBackground` /
/// `usesHostLayerBackground` entry points to it, and writes
/// ``lastAppearanceColorScheme`` from its own initialize/reload paths, so every
/// app-side call site stays byte-identical.
///
/// Isolation design: the legacy state was plain `var` storage on the
/// non-isolated `GhosttyApp` class, mutated only on the main thread by
/// convention (initialize, configuration reload, appearance/theme and ghostty
/// action callbacks all run on main). This drain preserves that exact
/// non-isolated shape as a plain `final class` (not `Sendable`, not
/// `@MainActor`), mirroring the sibling ``TerminalDefaultAppearanceState`` so the
/// host keeps constructing and calling it byte-identically with no `@MainActor`
/// ripple onto its non-isolated callers. The host is held weakly because the
/// host owns this coordinator; in practice the host is the process-lifetime
/// engine singleton and is never deallocated before a call lands.
public final class TerminalAppearanceCoordinator {
    /// The app-target seam for live ghostty / reload / log effects.
    public weak var host: (any TerminalAppearanceHosting)?

    /// The color-scheme preference last applied to the live configuration. The
    /// host writes this from its initialize and reload paths; the appearance-sync
    /// path reads and updates it here.
    public var lastAppearanceColorScheme: GhosttyConfig.ColorSchemePreference?

    /// The runtime `ghostty_color_scheme_e` last pushed to libghostty, used to
    /// suppress redundant pushes.
    private var appliedGhosttyRuntimeColorScheme: ghostty_color_scheme_e?

    /// Reentrancy depth of an in-flight runtime color-scheme synchronization.
    private var runtimeColorSchemeSynchronizationDepth = 0

    /// Whether the terminal renders against a host-layer (window-owned)
    /// background rather than the ghostty-renderer-owned background image.
    public private(set) var usesHostLayerBackground = false

    /// Creates the coordinator bound to its app-target host seam.
    public init(host: (any TerminalAppearanceHosting)?) {
        self.host = host
    }

    /// Folds the current system color-scheme preference into a runtime appearance
    /// update, reloading the ghostty configuration when the preference changed.
    public func synchronizeThemeWithAppearance(source: String) {
        guard let host else { return }
        let currentColorScheme = GhosttyConfig.currentColorSchemePreference()
        let plan = GhosttyConfig.appearanceSynchronizationPlan(
            previousColorScheme: lastAppearanceColorScheme,
            currentColorScheme: currentColorScheme
        )
        if host.appearanceBackgroundLogEnabled {
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
            host.appearanceLogBackground(
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
        host.appearanceReloadConfiguration(
            source: "appearanceSync:\(source)",
            preferredColorScheme: colorScheme
        )
    }

    /// Synchronizes the live ghostty runtime color scheme for a cmux
    /// color-scheme preference.
    public func synchronizeGhosttyRuntimeColorScheme(
        _ colorScheme: GhosttyConfig.ColorSchemePreference,
        source: String
    ) {
        synchronizeGhosttyRuntimeColorScheme(
            GhosttyConfig.ghosttyRuntimeColorScheme(for: colorScheme),
            colorScheme: colorScheme,
            source: source
        )
    }

    private func synchronizeGhosttyRuntimeColorScheme(
        _ runtimeColorScheme: ghostty_color_scheme_e,
        colorScheme: GhosttyConfig.ColorSchemePreference,
        source: String
    ) {
        guard let host, host.appearanceHasGhosttyApp else { return }
        let decision = GhosttyConfig.runtimeColorSchemeSynchronizationDecision(
            applied: appliedGhosttyRuntimeColorScheme,
            requested: runtimeColorScheme,
            isSynchronizing: runtimeColorSchemeSynchronizationDepth > 0
        )
        guard decision == .apply else {
            if host.appearanceBackgroundLogEnabled {
                let schemeLabel = colorScheme == .dark ? "dark" : "light"
                let reason: String
                switch decision {
                case .apply:
                    reason = "apply"
                case .skipReentrant:
                    reason = "reentrant"
                }
                host.appearanceLogBackground("app color scheme skipped source=\(source) scheme=\(schemeLabel) reason=\(reason)")
            }
            return
        }

        appliedGhosttyRuntimeColorScheme = runtimeColorScheme
        runtimeColorSchemeSynchronizationDepth += 1
        defer { runtimeColorSchemeSynchronizationDepth -= 1 }
        host.appearanceApplyGhosttyRuntimeColorScheme(runtimeColorScheme)
        if host.appearanceBackgroundLogEnabled {
            let schemeLabel = colorScheme == .dark ? "dark" : "light"
            host.appearanceLogBackground("app color scheme source=\(source) scheme=\(schemeLabel)")
        }
    }

    /// Whether a ghostty reload action should be processed now, or skipped
    /// because a reload or color-scheme synchronization is already in flight.
    public func shouldProcessGhosttyReloadAction(source: String, soft: Bool) -> Bool {
        guard let host else { return true }
        guard host.appearanceReloadConfigurationDepth == 0,
              runtimeColorSchemeSynchronizationDepth == 0 else {
            if host.appearanceBackgroundLogEnabled {
                host.appearanceLogBackground("theme action reload request skipped source=\(source) soft=\(soft) reason=reentrant")
            }
            return false
        }
        return true
    }

    /// Records whether the terminal renders against a host-layer background,
    /// returning whether the value changed.
    @discardableResult
    public func setUsesHostLayerBackground(_ newValue: Bool, source: String) -> Bool {
        let previous = usesHostLayerBackground
        usesHostLayerBackground = newValue
        let hasChanged = previous != newValue
        if hasChanged, let host, host.appearanceBackgroundLogEnabled {
            host.appearanceLogBackground(
                "terminal rendering mode changed source=\(source) usesHostLayerBackground=\(newValue) previous=\(previous)"
            )
        }
        return hasChanged
    }
}
