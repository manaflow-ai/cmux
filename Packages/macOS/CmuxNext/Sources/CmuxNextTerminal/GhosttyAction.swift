import GhosttyNextKit

/// One action from `action_cb`, copied out of C memory so it can cross an
/// actor hop.
nonisolated enum GhosttyAction: Sendable {
    case host(TerminalHostAction)
    case setTitle(String)
    case pwd(String)
    case ringBell
    case openURL(String)
    case mouseShape(ghostty_action_mouse_shape_e)
    case mouseVisible(Bool)
    case mouseOverLink(String?)
    case cellSize(width: UInt32, height: UInt32)
    case rendererHealthy(Bool)
    case progress(TerminalProgress?)
    case commandFinished(TerminalCommandResult)
    case childExited(exitCode: UInt32)
    case secureInput(ghostty_action_secure_input_e)
    case readOnly(Bool)
    case keySequence(active: Bool)
    case backgroundColor(red: UInt8, green: UInt8, blue: UInt8)
    /// A clone the receiver must adopt or free.
    case configChange(UncheckedPointer)
    case reloadConfig(soft: Bool)
    case openConfig
    case scrollbar(TerminalScrollbar)
    case startSearch(String)
    case endSearch
    case searchTotal(Int?)
    case searchSelected(Int?)
    case copyTitleToClipboard
    case render
}
