import Foundation

/// Structural actions that must be committed by cmuxd before Swift projects them.
enum TerminalBackendTopologyMutation: String, CaseIterable, Sendable {
    case createWorkspace
    case closeWorkspace
    case renameWorkspace
    case splitPane
    case closePane
    case attachSurface
    case closeTerminal
    case renameSurface
    case moveTab
    case reorderTab
    case reorderWorkspace
    case changeSplitRatio
    case reparentTerminal
}
