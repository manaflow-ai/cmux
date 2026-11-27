import CmuxTerminal

/// Per-surface state retained only while one config snapshot is being applied.
@MainActor
final class TerminalConfigurationSurfaceApplyState {
    weak var surface: TerminalSurface?
    let fontReloadState:
        TerminalFontSizeConfigurationReloadState
    var didApplyConfigurationStage = false

    init(
        surface: TerminalSurface,
        fontReloadState:
            TerminalFontSizeConfigurationReloadState
    ) {
        self.surface = surface
        self.fontReloadState = fontReloadState
    }
}
