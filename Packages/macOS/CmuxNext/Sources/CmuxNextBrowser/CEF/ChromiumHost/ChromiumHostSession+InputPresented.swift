#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.

/// The host's presentation feedback. The host reports when the frame that shows an input
/// reached the display, by the input's event time (`inputPresented`, from the fork's presentation feedback); the
/// session hands each report to ``InputPresented``, which in the app is the input latency tracker's
/// `hostPresented(eventNanos:at:)`, as Chrome's browser closes an input's latency at the presentation feedback of the
/// frame that carried it (cc/metrics/compositor_frame_reporter.cc). A frame that failed to present
/// (`gfx::PresentationFeedback::kFailure`) is counted and not handed on: the slot then closes at its deadline.
extension ChromiumHostSession {
    /// Takes the host's report that the frame showing the input of event time `eventNanos` reached the display at
    /// `presentedNanos` (both CLOCK_UPTIME_RAW nanoseconds).
    public typealias InputPresented = @MainActor (_ eventNanos: UInt64, _ presentedNanos: UInt64) -> Void
    /// Takes whether the current host reports each input's presentation (its `ready` said so; false once it ended),
    /// which in the app is the tracker's `pagesReportPresentation`: a page slot waits for a report only while one
    /// can come.
    public typealias ReportsInputPresented = @MainActor (_ reports: Bool) -> Void

    /// Hands an `inputPresented` frame of the current host on, or counts it when its frame failed to present.
    func takeInputPresented(_ frame: ChromiumHostFrame) {
        guard let presented = frame.inputPresentedFields else { return }
        guard presented.feedbackFlags & ChromiumHostFrame.presentationFailed == 0 else {
            failedInputPresentations += 1
            return
        }
        inputPresented(presented.eventNanos, presented.presentedNanos)
    }
}
#endif
