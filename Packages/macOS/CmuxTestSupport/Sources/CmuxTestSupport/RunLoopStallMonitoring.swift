#if DEBUG
/// Seam for the DEBUG main-run-loop stall probe.
///
/// The app's composition root constructs a concrete monitor
/// (``CmuxMainRunLoopStallMonitor``) and holds it as `any RunLoopStallMonitoring`,
/// calling ``installIfNeeded()`` once during launch. The probe attaches a
/// `CFRunLoopObserver` to the main run loop and logs a `runloop.stall` line
/// whenever the gap between consecutive observer activities exceeds the internal
/// threshold. Inverting the install behind this protocol lets the app drop the
/// former `static let shared` singleton in favor of one constructor-injected
/// instance.
///
/// Isolation: `@MainActor`. The single caller
/// (`applicationDidFinishLaunching`) runs on the main actor, the observer is
/// attached to the main run loop, and the conformer reads main-actor state, so
/// the whole seam lives on the main actor.
@MainActor
public protocol RunLoopStallMonitoring: AnyObject {
    /// Attaches the main-run-loop stall observer the first time it is called,
    /// gated by the typing-timing probe being enabled. Subsequent calls are
    /// no-ops once installed.
    func installIfNeeded()
}
#endif
