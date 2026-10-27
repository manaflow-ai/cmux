import CmuxNextMetrics
import CmuxNextSignposts
import CmuxNextTrace
import QuartzCore

/// The remote desktop stream's frame trace points and histograms: `remote.frame_decoded` when a decoded frame
/// reaches the presenter, `remote.present` stamped with the time the display showed it (with the newest input it
/// echoes), and the `remote.input_to_present` and `smoothness.dropped_pct.remote_stream` samples
/// (``RemoteStreamPresentLedger``).
///
/// The present time is the display's own (`MTLDrawable.presentedTime`, Chrome's `gfx::PresentationFeedback`
/// timestamp that ends `EventLatency`), not an estimate. Present results arrive on Metal's thread; they queue, in
/// order, to one task that owns the ledger (``Recorder``), so the window arithmetic sees frames in present order.
nonisolated final class RemotePresentLog: Sendable {
    private nonisolated struct Present: Sendable {
        var frame: UInt32
        var echo: RemoteInputEcho
        var mediaTime: CFTimeInterval
    }

    private let runtime: TraceRuntime
    private let presents: AsyncStream<Present>.Continuation

    /// - Parameter inputLatency: The pane's input send times; its runtime takes the trace points and histograms.
    init(inputLatency: RemoteInputLatency) {
        runtime = inputLatency.runtime
        // Two drawables and a display refresh per present: 64 results only queue while the task is starved.
        let (stream, continuation) = AsyncStream.makeStream(of: Present.self, bufferingPolicy: .bufferingOldest(64))
        presents = continuation
        Task(priority: .utility) {
            var recorder = Recorder(inputLatency: inputLatency)
            for await present in stream {
                recorder.presentCompleted(frame: present.frame, echo: present.echo, presentedAt: present.mediaTime)
            }
        }
    }

    deinit {
        presents.finish()
    }

    /// Host frame `frame` was decoded and handed to the presenter (any thread).
    func frameDecoded(_ frame: UInt32) {
        runtime.event(.remoteFrameDecoded, arg0: UInt64(frame))
    }

    /// The display finished with host frame `frame`, which shows the inputs in `echo`. Call in present order.
    ///
    /// - Parameter mediaTime: When the display showed it (`CACurrentMediaTime` seconds), or 0 when it never did.
    func presentCompleted(frame: UInt32, echo: RemoteInputEcho, presentedAt mediaTime: CFTimeInterval) {
        presents.yield(Present(frame: frame, echo: echo, mediaTime: mediaTime))
    }
}

extension RemotePresentLog {
    /// Writes `remote.present` and the two histograms for each present result, in order.
    nonisolated struct Recorder: Sendable {
        private let inputLatency: RemoteInputLatency
        private let metrics: Metrics
        private var ledger = RemoteStreamPresentLedger()

        init(inputLatency: RemoteInputLatency) {
            self.inputLatency = inputLatency
            metrics = Metrics(runtime: inputLatency.runtime)
        }

        /// Host frame `frame`, which shows the inputs in `echo`, was shown at `mediaTime` (`CACurrentMediaTime`
        /// seconds), or never when `mediaTime` is 0. `remote.present` carries the display's time, not this call's.
        mutating func presentCompleted(frame: UInt32, echo: RemoteInputEcho, presentedAt mediaTime: CFTimeInterval) {
            let shown = mediaTime > 0
            if shown {
                let presentNanos = TraceClock.nanos(fromMediaTime: mediaTime)
                inputLatency.runtime.event(.remotePresent, atNanos: presentNanos, arg0: UInt64(frame),
                                           arg1: UInt64(echo.newest))
                let presentMicros = UInt32(truncatingIfNeeded: presentNanos / 1_000)
                for sequence in ledger.newlyShownInputs(echo: echo) {
                    guard let sent = inputLatency.sentMicros(sequence) else { continue }
                    metrics.record(.remoteInputToPresent, Int64(presentMicros &- sent))
                }
            }
            if let percent = ledger.frameCompleted(frame, shown: shown) {
                metrics.record(.smoothnessDroppedPercent(.remoteStream), percent)
            }
        }
    }
}
