import CmuxTerminal
import CmuxTerminalCore

extension GhosttySurfaceCallbackContext {
    /// Copies callback-scoped values before handing confirmation to the UI actor.
    func scheduleClipboardReadConfirmation(
        _ text: String,
        stateAddress: UInt,
        surfaceAddress: UInt,
        surfaceGeneration: UInt64
    ) {
        Task { @MainActor in
            confirmClipboardRead(
                text,
                stateAddress: stateAddress,
                surfaceAddress: surfaceAddress,
                surfaceGeneration: surfaceGeneration
            )
        }
    }

    @MainActor
    func confirmClipboardRead(
        _ text: String,
        stateAddress: UInt,
        surfaceAddress: UInt,
        surfaceGeneration: UInt64
    ) {
        surfaceView?.clipboardReadRequiresConfirmation(stateAddress)
        guard let state = UnsafeMutableRawPointer(bitPattern: stateAddress),
              let terminalSurface,
              terminalSurface.runtimeSurfaceGeneration == surfaceGeneration,
              let surface = terminalSurface.surface,
              UInt(bitPattern: surface) == surfaceAddress else {
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
        terminalSurface.noteClipboardReadCompleted()
        surfaceView?.completeClipboardRead(stateAddress, confirmed: true)
    }
}
