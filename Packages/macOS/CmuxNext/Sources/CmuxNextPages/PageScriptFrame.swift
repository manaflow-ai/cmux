package import CmuxNextWakeups

/// The next display frame a page's batched envelopes wait for (``PageScriptPipeline/deliverOnFrames(_:)``,
/// the `pageScriptFrames` feature), as tasks of the main-thread board. ``WebUIHost/scriptFrames`` hands it
/// to its pages, the preloads it opens among them.
///
/// The pipeline asks for a flush with the cause of the send that asked (``currentCause``), and asks
/// again when a later send of the same frame has a cause that runs sooner (a person's or the
/// frontend's after a program's): the flush runs in the class of the highest cause asked for, as a
/// ``VisibleObservation``'s does (p06-scheduler.md section C, not "the first cause wins").
package struct PageScriptFrame {
    /// The cause of the change being made now (``ObservationCauses/currentCause``).
    package let currentCause: @MainActor () -> ObservationCause
    /// Calls `flush` once on the next frame, in the class `cause` names.
    package let schedule: @MainActor (_ cause: ObservationCause, _ flush: @escaping @MainActor () -> Void) -> Void

    package init(currentCause: @escaping @MainActor () -> ObservationCause,
                 schedule: @escaping @MainActor (_ cause: ObservationCause, _ flush: @escaping @MainActor () -> Void) -> Void) {
        self.currentCause = currentCause
        self.schedule = schedule
    }
}

extension FrameBatchQueue {
    /// The page frame of this budgeted queue: each flush is one task of the queue. A flush that a
    /// person's or the frontend's change asked for runs unbudgeted on the next frame
    /// (``FrameBatchQueue/enqueue(cause:_:)``); the rest keeps the queue's class budget, so a page
    /// update never delays the person's input.
    package func pageScriptFrame(causes: ObservationCauses) -> PageScriptFrame {
        PageScriptFrame(currentCause: { causes.currentCause },
                        schedule: { [self] cause, flush in enqueue(cause: cause, flush) })
    }
}
