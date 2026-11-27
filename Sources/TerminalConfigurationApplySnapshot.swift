import Foundation
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

    private var surfaceStates:
        [UUID: TerminalConfigurationSurfaceApplyState] = [:]

    init(
        source: String,
        preferredColorScheme:
            GhosttyConfig.ColorSchemePreference,
        previousMagnificationPercent: Int,
        terminalFontConfiguration:
            WorkspaceTerminalFontConfigurationSnapshot
    ) {
        self.source = source
        self.preferredColorScheme = preferredColorScheme
        self.previousMagnificationPercent =
            previousMagnificationPercent
        self.terminalFontConfiguration =
            terminalFontConfiguration
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
