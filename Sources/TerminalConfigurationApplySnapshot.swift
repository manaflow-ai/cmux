import CmuxTerminal

/// Shared immutable config-derived values plus bounded per-surface retry state.
@MainActor
final class TerminalConfigurationApplySnapshot {
    let source: String
    let preferredColorScheme:
        GhosttyConfig.ColorSchemePreference
    let previousMagnificationPercent: Int
    let terminalFontConfiguration:
        WorkspaceTerminalFontConfigurationSnapshot
    let appliesNativeConfiguration: Bool
    let refreshesHostAppearance: Bool
    private(set) var needsRecovery = false

    private var surfaceStates:
        [UUID: TerminalConfigurationSurfaceApplyState] = [:]

    init(
        source: String,
        preferredColorScheme:
            GhosttyConfig.ColorSchemePreference,
        previousMagnificationPercent: Int,
        terminalFontConfiguration:
            WorkspaceTerminalFontConfigurationSnapshot,
        appliesNativeConfiguration: Bool = true,
        refreshesHostAppearance: Bool = true
    ) {
        self.source = source
        self.preferredColorScheme = preferredColorScheme
        self.previousMagnificationPercent =
            previousMagnificationPercent
        self.terminalFontConfiguration =
            terminalFontConfiguration
        self.appliesNativeConfiguration = appliesNativeConfiguration
        self.refreshesHostAppearance = refreshesHostAppearance
    }

    /// Marks that at least one surface needs another reload attempt.
    func markNeedsRecovery() {
        needsRecovery = true
    }

    func surfaceState(
        lifecycleID: UUID
    ) -> TerminalConfigurationSurfaceApplyState? {
        surfaceStates[lifecycleID]
    }

    func recordSurfaceState(
        _ state: TerminalConfigurationSurfaceApplyState,
        lifecycleID: UUID
    ) {
        surfaceStates[lifecycleID] = state
    }

    @discardableResult
    func removeSurfaceState(
        lifecycleID: UUID
    ) -> TerminalConfigurationSurfaceApplyState? {
        surfaceStates.removeValue(forKey: lifecycleID)
    }
}
