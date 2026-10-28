extension MainThreadWatchdog {
    /// Where a main-thread hang that may end the app goes: every hang episode, not
    /// rate-limited as ``onHang`` is, so the one the person ends with Force Quit or the system ends with SIGKILL
    /// is on disk when the process dies. The app writes it as the run's fatal-hang record and the next launch
    /// reports it, as Sentry's fatal app hangs do (`SentryANRTrackingIntegration`): Chrome's HangWatcher dumps
    /// a hung browser while it still runs (base/threading/hang_watcher.cc), and its clean-exit beacon tells the
    /// next launch the run did not end (components/metrics/clean_exit_beacon.cc).
    ///
    /// Each closure runs on the watchdog thread and may do one small blocking file write: that thread is the
    /// only one still running the app's logic while the main thread is stuck.
    public struct FatalHangSink: Sendable {
        /// The episode began (the stall reached the hang threshold), with the main thread's stack sampled while it
        /// was still stuck and the stall's start (`CLOCK_UPTIME_RAW` nanoseconds). Not called when the stall ended
        /// before the sample.
        public var began: @Sendable (_ hang: Hang, _ startUptimeNanos: UInt64) -> Void
        /// The episode is still running at a checkpoint (4 s, 8 s, 16 s, ...): the time since its start.
        public var progressed: @Sendable (_ elapsedNanos: UInt64) -> Void
        /// The main thread answered again, or the watchdog stopped.
        public var ended: @Sendable () -> Void

        public init(began: @escaping @Sendable (_ hang: Hang, _ startUptimeNanos: UInt64) -> Void,
                    progressed: @escaping @Sendable (_ elapsedNanos: UInt64) -> Void,
                    ended: @escaping @Sendable () -> Void) {
            self.began = began
            self.progressed = progressed
            self.ended = ended
        }
    }

    /// Receives every hang episode's start, checkpoints and end on the watchdog thread (``FatalHangSink``); nil
    /// (the default) records nothing.
    ///
    /// Lock carve-out: as ``onHang``'s sink, `fatalHangSink` is set once at launch and read on the watchdog thread
    /// once per episode event; it is never held across a call.
    public var fatalHangs: FatalHangSink? {
        get { fatalHangSink.withLock { $0 } }
        set { fatalHangSink.withLock { $0 = newValue } }
    }
}
