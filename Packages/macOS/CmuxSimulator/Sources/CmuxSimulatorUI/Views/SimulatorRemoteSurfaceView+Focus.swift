import AppKit

extension SimulatorRemoteSurfaceView {
    func requestFocus(generation: UInt64) {
        guard generation > handledFocusGeneration else { return }
        pendingFocusGeneration = max(pendingFocusGeneration ?? 0, generation)
        fulfillPendingFocusRequest()
    }

    func fulfillPendingFocusRequest() {
        guard let generation = pendingFocusGeneration,
              generation > handledFocusGeneration,
              let window,
              window.makeFirstResponder(self) else {
            return
        }
        handledFocusGeneration = generation
        if pendingFocusGeneration == generation {
            pendingFocusGeneration = nil
        }
    }
}
