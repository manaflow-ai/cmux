import CmuxControlSocket
import CmuxDictation
import Foundation

/// Delivers finalized dictation transcripts to the focused terminal surface,
/// through the same shared path the `surface.send_text` socket command uses
/// (focused-surface routing, hibernation resume, queue-full handling).
struct DictationSurfaceTextSink: DictationTextSink {
    func insertDictationText(_ text: String) -> Bool {
        let resolution = TerminalController.shared.controlSurfaceSendText(
            routing: ControlRoutingSelectors(
                hasWindowIDParam: false,
                windowID: nil,
                groupID: nil,
                workspaceID: nil,
                surfaceID: nil,
                paneID: nil
            ),
            surfaceID: nil,
            hasSurfaceIDParam: false,
            text: text
        )
        switch resolution {
        case .sent:
            return true
        case .tabManagerUnavailable, .workspaceNotFound, .surfaceNotFoundForID,
             .noFocusedSurface, .surfaceNotTerminal, .unknownKey, .inputQueueFull,
             .surfaceUnavailable, .processExited:
            return false
        }
    }
}
