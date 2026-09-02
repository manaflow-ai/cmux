import CmuxTerminal
import Foundation

/// The native pane and transport owner returned by cloud materialization.
struct CloudManualMirrorMaterialization {
    let workspaceID: UUID
    let panelID: UUID
    let surface: TerminalSurface
    let session: CloudTuiManualMirrorSession
}
