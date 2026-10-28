public import CmuxNextControl
public import CmuxNextWakeups
import Observation

/// Whether a trace recording runs, for the indicator in every window's top row (p09-observability task 133).
/// `trace.start` shows it and `trace.stop`, the cap or the indicator's Stop hides it (``TraceControl``, task 020):
/// an agent can start a recording, so the person always sees one run and can end it.
///
/// Chrome does the same for every capture a page or an extension starts: `MediaStreamCaptureIndicator`
/// (chrome/browser/media/webrtc/media_stream_capture_indicator.h) keeps the state, and
/// `ScreenCaptureNotificationUI` (chrome/browser/ui/screen_capture_notification_ui.h) shows it with a Stop
/// button whose callback ends the capture where it was started.
///
/// ```swift
/// let recording = TraceRecordingState(work: work)
/// TraceControlParts(app: ring, indicator: recording, secureInput: secureInput)
/// TraceRecordingIndicatorView(state: recording, node: window.visibility, mainWork: mainWork) { relayout() }
/// ```
@MainActor @Observable
public final class TraceRecordingState: TraceRecordingIndicator {
    /// Where the recording is.
    public nonisolated enum Phase: Sendable, Equatable {
        /// No recording runs: the indicator is hidden.
        case idle
        /// A recording runs: the indicator shows with Stop.
        case recording
        /// The person pressed Stop and the recording's parts are stopping.
        case stopping
    }

    /// Where the recording is now (observed by each window's indicator).
    public private(set) var phase = Phase.idle

    /// Ends the running recording (``TraceControl``'s indicator stop); nil while none runs.
    @ObservationIgnored private var stop: (@Sendable () async -> Void)?
    /// The last Stop's run (tests await it).
    @ObservationIgnored private(set) var stopRun: Task<Void, any Error>?
    private let work: BackgroundWork

    /// - Parameter work: Runs the stop off the main actor.
    public init(work: BackgroundWork) {
        self.work = work
    }

    public func show(stop: @escaping @Sendable () async -> Void) {
        self.stop = stop
        phase = .recording
    }

    public func hide() {
        stop = nil
        phase = .idle
    }

    /// The indicator's Stop: shows the stop at once and ends the recording in every part it reached. ``hide()``
    /// follows when the parts stopped; a second press while stopping does nothing.
    public func requestStop() {
        guard phase == .recording, let stop else { return }
        phase = .stopping
        stopRun = work.task(.userVisible) { await stop() }
    }
}
