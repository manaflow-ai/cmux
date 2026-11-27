/// Receives each new main-thread blocking call site once per launch (the app: ``BlockingLogSink``;
/// to come: the opt-in hang reports; tests: a recorder).
///
/// ``BlockingDetector/install(sink:)`` installs one at the composition root. ``record(_:)`` runs
/// on the detector's drain queue (`com.cmuxterm.app.next.blocking-drain`, utility QoS), never on
/// the thread that blocked and never inside its locks, so it may take its own locks; it should
/// still only copy the value.
public protocol BlockingViolationSink: AnyObject, Sendable {
    /// Takes one new violation.
    func record(_ violation: BlockingViolation)
}
