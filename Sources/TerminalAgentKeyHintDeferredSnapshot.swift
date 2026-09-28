import CmuxTerminal

/// A fresh read of the state protected by a deferred hint request.
struct TerminalAgentKeyHintDeferredSnapshot {
    let terminalSurface: TerminalSurface
    let runtimeSurfaceGeneration: UInt64
    let panel: TerminalPanel
    let cell: TerminalAgentKeyHintCell
    let row: String
    let viewport: TerminalAgentKeyHintViewportState
    let hasSelection: Bool
    let mouseCaptured: Bool
}
