/// The stability counts and their denominators (plans/cmux-next/chrome-parity/p09-observability.md task 109):
/// launches and active seconds, how a run ended when it did not quit as asked, how each kind of child process
/// ended, and a daemon that stopped answering. Each source calls one method, once per event.
///
/// Chrome's model: `StabilityMetricsHelper::RecordStabilityEvent` (components/metrics/stability_metrics_helper.cc)
/// counts each event as one sample of the `Stability.Counts2` enumeration histogram, with launches as the
/// denominator, and the counts live in the persistent histogram allocator, so a crash keeps them for the next
/// launch's log. Here each count is a sample of a catalog histogram in the process's ``MetricsStore``: its
/// `MAP_SHARED` file survives a crash, and the next launch folds that file as the crashed launch's own section
/// (``MetricsLaunchFold``); schema 3 sends the samples as `stability{}` (task 063). A record is three relaxed atomic
/// adds; with no store attached it records nothing.
///
/// ```swift
/// let stability = StabilityCounters()
/// stability.launched(StabilityCounters.Launch(previousExit: marker.previousExit))
/// stability.childExited(.daemon, .signal)
/// ```
public struct StabilityCounters: Sendable {
    /// The recorder the counts go through.
    public let metrics: Metrics

    /// Counts into `metrics`' store (the app's by default; tests pass their own runtime's).
    public init(metrics: Metrics = Metrics()) {
        self.metrics = metrics
    }

    /// What a launch counts: itself (`stability.launch`, the denominator) and how the run before it ended when that
    /// run did not quit as asked.
    public struct Launch: Sendable, Equatable {
        /// The previous run's unclean end (`AppRunMarker.previousExit`); nil after a quit or on a first launch.
        public var previousExit: HistogramID.UncleanExit?

        /// A launch after a run that ended as `previousExit` says.
        public init(previousExit: HistogramID.UncleanExit?) {
            self.previousExit = previousExit
        }
    }

    /// This launch began: one `stability.launch` and, after an unclean end, one `stability.unclean_exit` sample of
    /// its kind. Called once per launch, into the store this launch's metrics file holds.
    public func launched(_ launch: Launch) {
        metrics.record(.stabilityLaunch, 1)
        if let exit = launch.previousExit { metrics.record(.stabilityUncleanExit, exit.rawValue) }
    }

    /// The app was active for `seconds` more whole seconds (Chrome's active-time rule, `ActiveTimeLedger`); a
    /// value below 1 counts nothing. Each call adds its seconds to the histogram's sum, which is what reports send.
    public func active(seconds: Int) {
        guard seconds > 0 else { return }
        metrics.record(.stabilityActiveSeconds, Int64(seconds))
    }

    /// A child process of `kind` ended as `exit` says.
    public func childExited(_ kind: HistogramID.ProcessKind, _ exit: HistogramID.ChildExit) {
        metrics.record(.stabilityChildExit(kind), exit.rawValue)
    }

    /// A daemon stopped answering; `lastRequest` is the class of the last request the app sent it, nil (counted as
    /// `other`) when it had sent none.
    public func daemonUnresponsive(lastRequest: HistogramID.MethodClass?) {
        let classes = HistogramID.MethodClass.allCases
        let position = classes.firstIndex(of: lastRequest ?? .other) ?? classes.count - 1
        metrics.record(.daemonUnresponsive, Int64(position))
    }
}

extension HistogramID.ChildExit {
    /// How a child ended, from its `waitpid` status: a normal exit with status 0 is clean, any other exit status is
    /// a fatal error the process reported (Rust's panic exit is 101), and an end by a signal is `signal`, or `oom`
    /// when the kernel said it ended the process for memory (`NOTE_EXIT_MEMORY`, `outOfMemory`).
    public init(waitStatus status: Int32, outOfMemory: Bool = false) {
        // <sys/wait.h>: WIFEXITED is `(status & 0177) == 0`, WEXITSTATUS is `(status >> 8) & 0xff`.
        if outOfMemory {
            self = .oom
        } else if status & 0o177 == 0 {
            self = (status >> 8) & 0xFF == 0 ? .clean : .panic
        } else {
            self = .signal
        }
    }
}
