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

    private var surfaceStates:
        [ObjectIdentifier: TerminalConfigurationSurfaceApplyState] = [:]

    init(
        source: String,
        preferredColorScheme:
            GhosttyConfig.ColorSchemePreference,
        previousMagnificationPercent: Int,
        terminalFontConfiguration:
            WorkspaceTerminalFontConfigurationSnapshot,
        appliesNativeConfiguration: Bool,
        refreshesHostAppearance: Bool
    ) {
        self.source = source
        self.preferredColorScheme = preferredColorScheme
        self.previousMagnificationPercent =
            previousMagnificationPercent
        self.terminalFontConfiguration =
            terminalFontConfiguration
        self.appliesNativeConfiguration =
            appliesNativeConfiguration
        self.refreshesHostAppearance =
            refreshesHostAppearance
    }

    func surfaceState(
        identity: ObjectIdentifier
    ) -> TerminalConfigurationSurfaceApplyState? {
        surfaceStates[identity]
    }

    func recordSurfaceState(
        _ state: TerminalConfigurationSurfaceApplyState,
        identity: ObjectIdentifier
    ) {
        surfaceStates[identity] = state
    }

    @discardableResult
    func removeSurfaceState(
        identity: ObjectIdentifier
    ) -> TerminalConfigurationSurfaceApplyState? {
        surfaceStates.removeValue(forKey: identity)
    }
}
