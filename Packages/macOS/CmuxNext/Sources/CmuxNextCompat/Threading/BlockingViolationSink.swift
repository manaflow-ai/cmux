/// Receives each new main-thread, pool or `.cpu` lane blocking call site once per launch (the app's
/// `BlockingReportSink`: opt-in hang reports and consented crash reports; ``BlockingLogSink``: one unified-log
/// line per site; tests: a recorder).
///
/// ``BlockingDetector/install(sink:)`` installs one at the composition root and replays to it every
/// site recorded before. ``record(_:)`` runs
/// on the detector's drain queue (`com.cmuxterm.app.next.blocking-drain`, utility QoS), never on
/// the thread that blocked and never inside its locks, so it may take its own locks; it should
/// still only copy the value.
public protocol BlockingViolationSink: AnyObject, Sendable {
    /// Takes one new violation.
    func record(_ violation: BlockingViolation)
}
