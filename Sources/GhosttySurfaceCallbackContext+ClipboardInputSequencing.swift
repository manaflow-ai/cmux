import CmuxTerminal
import CmuxTerminalCore

extension GhosttySurfaceCallbackContext {
    @MainActor
    func confirmClipboardRead(
        _ text: String,
        stateAddress: UInt
    ) {
        surfaceView?.clipboardReadRequiresConfirmation(stateAddress)
        guard let state = UnsafeMutableRawPointer(bitPattern: stateAddress),
              let surface = runtimeSurface else {
            surfaceView?.completeClipboardRead(
                stateAddress,
                confirmed: true
            )
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
        terminalSurface?.noteClipboardReadCompleted()
        surfaceView?.completeClipboardRead(stateAddress, confirmed: true)
    }
}
