public import CmuxNextAppearance
public import CmuxNextDesignTokens

/// The density chrome draws in now.
nonisolated extension DensityTokens {
    /// A density that code inside `$scoped.withValue` draws in instead of the app's: a preview
    /// that draws rows at another density without switching the app, and tests that lay out
    /// views at each density without touching the app-wide `DesignSettings.shared`. A task-local
    /// value, so it reaches only that scope and the tasks it starts.
    @TaskLocal public static var scoped: DensityTokens?
}

extension DensityTokens {
    /// The scoped density, else the app's (`DesignSettings.shared.densityTokens`). Reading it
    /// inside an Observation-tracked scope registers a dependency on the app's density.
    @MainActor public static var active: DensityTokens { scoped ?? DesignSettings.shared.densityTokens }
}
