import CmuxTerminal
import Foundation

/// Uses the existing clipboard input sequencer for a paste prepared before
/// Ghostty became ready, so later keystrokes cannot overtake the upload.
@MainActor
final class CloudImagePasteInputLease {
    private weak var view: GhosttyNSView?
    private weak var surface: TerminalSurface?
    private let epoch: UInt64
    private var finished = false
    // A live Swift object and a live native clipboard request cannot occupy
    // the same address. Retaining this lease fences native request-id reuse.
    private var requestID: UInt { UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque()) }

    init(view: GhosttyNSView, operation: TerminalImageTransferOperation) {
        self.view = view
        surface = view.terminalSurface
        epoch = view.terminalSurface?.runtimeSurfaceGeneration ?? .max
        view.terminalClipboardInputSequencer.beginRequest(id: requestID, epoch: epoch) { [weak self] in
            _ = operation.cancel()
            self?.finish()
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        guard let view else { return }
        if view.terminalSurface === surface, view.terminalSurface?.runtimeSurfaceGeneration == epoch {
            view.completeClipboardRead(requestID, confirmed: true)
        } else {
            view.cancelClipboardRead(requestID, currentEpoch: view.terminalSurface?.runtimeSurfaceGeneration ?? .max,
                                     deferredInputDisposition: .discard)
        }
    }
}
