import Dispatch

/// Turns the main-thread watchdog's hang episode reports into Sentry app-hang
/// events, at most one per episode: the process has one hang watcher, as
/// Chrome has one `HangWatcher` per process (`base/threading/hang_watcher.h`),
/// which detects and reports on its own thread, and the SDK's ANR thread is off.
///
/// The watchdog reports each episode on its thread while the main thread is
/// still blocked, at its hang threshold and at doubling checkpoints, each with a
/// fresh sample (``noteBlocked(duration:previous:addresses:otherThreads:)``),
/// then once when it ends, with the exact length (``noteEnded(duration:lastReport:addresses:otherThreads:)``).
/// The first report at or past ``threshold`` (8 s, the SDK's former
/// `appHangTimeoutInterval`) sends one ongoing event with that report's stacks,
/// so a hang the person ends by force-quitting is still reported. An episode
/// that ends past ``threshold`` before such a report sends one event with its
/// exact length. A shorter episode sends nothing here (its stall is a lag
/// spike, ``LagSpikeReporter``). No state, timer or lock: each decision is
/// read from the report and the one before it.
public struct AppHangReporter: Sendable {
    /// The sink an episode's event goes to (crash reporting in the app; a
    /// recorder in tests). Called on the watchdog thread: it must not wait.
    public typealias Sink = @Sendable (AppHangEvent) -> Void

    /// An episode is an app hang once the main thread is blocked this long.
    public let threshold: Duration
    private let sink: Sink

    /// Reports to `reporter` while it runs, on its own utility queue: the event
    /// reads debug images (`dladdr`), which can wait on the loader lock the hung
    /// main thread holds, and the watchdog thread must keep watching.
    public init(reporter: CrashReporter) {
        let queue = DispatchQueue(label: "com.cmuxterm.app.next.crash-reporting.app-hangs", qos: .utility)
        self.init(threshold: CrashReporter.appHangThreshold) { event in
            guard reporter.isStarted else { return }
            queue.async { reporter.reportAppHang(event) }
        }
    }

    /// Test seam: the threshold and the sink.
    public init(threshold: Duration, sink: @escaping Sink) {
        self.threshold = threshold
        self.sink = sink
    }

    /// The episode is still blocked after `duration`, with the stacks sampled now;
    /// `previous` is the duration of its previous report, nil for its first.
    public func noteBlocked(duration: Duration, previous: Duration?, addresses: [UInt],
                            otherThreads: [(name: String, addresses: [UInt])] = []) {
        guard duration >= threshold, (previous ?? .zero) < threshold else { return }
        sink(AppHangEvent(duration: duration, ongoing: true, addresses: addresses, otherThreads: otherThreads))
    }

    /// The episode ended after exactly `duration`. `lastReport` is the duration of
    /// its last ``noteBlocked(duration:previous:addresses:otherThreads:)`` (nil for
    /// none), and `addresses` and `otherThreads` that report's stacks.
    public func noteEnded(duration: Duration, lastReport: Duration?, addresses: [UInt],
                          otherThreads: [(name: String, addresses: [UInt])] = []) {
        guard duration >= threshold, (lastReport ?? .zero) < threshold else { return }
        sink(AppHangEvent(duration: duration, ongoing: false, addresses: addresses, otherThreads: otherThreads))
    }
}
