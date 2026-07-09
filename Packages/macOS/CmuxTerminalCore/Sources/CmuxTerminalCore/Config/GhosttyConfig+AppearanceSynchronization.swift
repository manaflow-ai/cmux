public import GhosttyKit

// Pure decisions that fold a color-scheme change into a runtime appearance
// update. These are functions of the previous/current color-scheme preferences
// plus a few booleans; they own no state and touch no handle, so they live as
// static members on the config value type whose ColorSchemePreference they
// operate on. The app-target engine forwards to them and applies the result to
// the live ghostty runtime.
extension GhosttyConfig {
    /// Whether a color-scheme change from `previousColorScheme` to
    /// `currentColorScheme` requires reloading the ghostty configuration.
    public static func shouldReloadConfigurationForAppearanceChange(
        previousColorScheme: ColorSchemePreference?,
        currentColorScheme: ColorSchemePreference
    ) -> Bool {
        previousColorScheme != currentColorScheme
    }

    /// The plan for synchronizing the ghostty runtime with a color-scheme change:
    /// either no work, or a reload carrying the target preference and its runtime
    /// `ghostty_color_scheme_e`.
    public enum AppearanceSynchronizationPlan {
        case unchanged
        case reload(
            colorScheme: ColorSchemePreference,
            runtimeColorScheme: ghostty_color_scheme_e
        )

        public var shouldReloadConfiguration: Bool {
            switch self {
            case .unchanged:
                return false
            case .reload:
                return true
            }
        }
    }

    /// Whether to apply a requested runtime color scheme or skip it because a
    /// synchronization pass is already in flight (reentrancy guard).
    public enum RuntimeColorSchemeSynchronizationDecision: Equatable {
        case apply
        case skipReentrant
    }

    /// Decides whether to apply or skip a requested runtime color-scheme update.
    /// Reentrant requests (those raised while a synchronization is already
    /// running) are skipped.
    public static func runtimeColorSchemeSynchronizationDecision(
        applied _: ghostty_color_scheme_e?,
        requested _: ghostty_color_scheme_e,
        isSynchronizing: Bool
    ) -> RuntimeColorSchemeSynchronizationDecision {
        if isSynchronizing {
            return .skipReentrant
        }
        return .apply
    }

    /// Builds the ``AppearanceSynchronizationPlan`` for a color-scheme change.
    public static func appearanceSynchronizationPlan(
        previousColorScheme: ColorSchemePreference?,
        currentColorScheme: ColorSchemePreference
    ) -> AppearanceSynchronizationPlan {
        guard shouldReloadConfigurationForAppearanceChange(
            previousColorScheme: previousColorScheme,
            currentColorScheme: currentColorScheme
        ) else {
            return .unchanged
        }

        return .reload(
            colorScheme: currentColorScheme,
            runtimeColorScheme: ghosttyRuntimeColorScheme(for: currentColorScheme)
        )
    }

    /// Maps a cmux ``ColorSchemePreference`` onto ghostty's runtime
    /// `ghostty_color_scheme_e`.
    public static func ghosttyRuntimeColorScheme(
        for colorScheme: ColorSchemePreference
    ) -> ghostty_color_scheme_e {
        switch colorScheme {
        case .light:
            return GHOSTTY_COLOR_SCHEME_LIGHT
        case .dark:
            return GHOSTTY_COLOR_SCHEME_DARK
        }
    }
}
