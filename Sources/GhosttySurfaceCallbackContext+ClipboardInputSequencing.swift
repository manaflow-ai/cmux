import CmuxTerminal
import CmuxTerminalCore

extension GhosttySurfaceCallbackContext {
    @MainActor
    func confirmClipboardRead(
        _ text: String,
        stateAddress: UInt,
        surfaceIdentity: TerminalClipboardRequestSurfaceIdentity
    ) {
        surfaceView?.clipboardReadRequiresConfirmation(stateAddress)
        guard let state = UnsafeMutableRawPointer(bitPattern: stateAddress),
              let terminalSurface,
              surfaceIdentity.matches(terminalSurface),
              let surface = terminalSurface.surface,
              UInt(bitPattern: surface) == surfaceIdentity.surfaceAddress else {
            surfaceView?.cancelClipboardRead(stateAddress)
            return
        }
        text.withCString { pointer in
            ghostty_surface_complete_clipboard_request(
                surface,
                pointer,
                state,
                true
            )
        }
        terminalSurface.noteClipboardReadCompleted()
        surfaceView?.completeClipboardRead(stateAddress, confirmed: true)
    }
}
