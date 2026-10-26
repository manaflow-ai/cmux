package import CmuxNextWakeups

/// Calls `flush` once on the next display frame, as one task of the main-thread board: the frame a
/// page's batched envelopes wait for (``PageScriptPipeline/deliverOnFrames(_:)``, the
/// `pageScriptFrames` feature). ``WebUIHost/scriptFrames`` and ``PageHostPool/scriptFrames`` hand it
/// to their pages.
package typealias PageScriptFrame = @MainActor (_ flush: @escaping @MainActor () -> Void) -> Void

extension FrameBatchQueue {
    /// The page frame of this budgeted queue: each page's flush is one task of the queue. A flush that a
    /// person's or the frontend's change asked for (`causes`' current cause when the page asked) runs
    /// unbudgeted on the next frame (``FrameBatchQueue/enqueue(cause:_:)``); the rest keeps the
    /// queue's class budget, so a page update never delays the person's input.
    package func pageScriptFrame(causes: ObservationCauses) -> PageScriptFrame {
        { [self] flush in enqueue(cause: causes.currentCause, flush) }
    }
}
