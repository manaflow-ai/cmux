import AppKit

/// Everything a deferred hint press must still match before it sends input.
struct TerminalAgentKeyHintDeferredRequest {
    let terminalSurfaceIdentity: ObjectIdentifier
    let runtimeSurfaceGeneration: UInt64
    let panelIdentity: ObjectIdentifier
    let cell: TerminalAgentKeyHintCell
    let row: String
    let viewport: TerminalAgentKeyHintViewportState
    let click: TerminalPanel.AgentKeyHintClick
    let modifierFlags: NSEvent.ModifierFlags
}
