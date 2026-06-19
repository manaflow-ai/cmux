/// Host seam through which ``SessionAutosaveScheduler`` drives the app's
/// session-snapshot autosave work.
///
/// The scheduler owns only the cadence (the repeating timer, the typing-quiet
/// deferral, and the in-flight latch); the actual snapshot build/save is
/// irreducibly app-coupled (it reads the live window/tab/sidebar tree and
/// writes the snapshot file), so it stays in the app target behind this seam.
/// `AppDelegate` conforms and the scheduler calls back into it on the main
/// actor.
///
/// **Why two callbacks instead of one.** The legacy autosave tick ran the
/// typing-quiet check and the in-flight latch on the main actor *before*
/// hopping to the async save work. ``performScheduledAutosave()`` is that async
/// save body; ``isTerminatingApp`` is read on every tick so a termination that
/// began between ticks suppresses the next save exactly as the legacy
/// `Self.shouldRunSessionAutosaveTick(isTerminatingApp:)` guard did.
@MainActor
public protocol SessionAutosaveScheduling: AnyObject {
    /// Whether the app is shutting down. The scheduler skips a tick when true,
    /// matching the legacy `shouldRunSessionAutosaveTick` guard that gated both
    /// the timer handler and the body entry.
    var isTerminatingApp: Bool { get }

    /// Runs the app's session-snapshot autosave: loads process-detected resume
    /// indexes, computes the autosave fingerprint, skips the write when the
    /// fingerprint is unchanged within the skippable interval, otherwise writes
    /// the snapshot and records the new fingerprint/persisted-at state.
    ///
    /// Lifted verbatim from the legacy `finishSessionAutosaveTick` body (minus
    /// the in-flight latch and timing instrumentation the scheduler now owns).
    /// Called on the main actor, awaited so the scheduler's in-flight latch
    /// spans the whole async body exactly as the legacy `Task { await ... }`
    /// plus `defer { tickInFlight = false }` did.
    func performScheduledAutosave(source: String) async
}
