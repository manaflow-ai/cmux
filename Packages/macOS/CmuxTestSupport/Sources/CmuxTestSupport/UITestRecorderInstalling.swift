#if DEBUG
/// The launch-time install seam for the app's ``UITestRecording`` recorders.
///
/// Each recorder owns the live app references it needs (``AppDelegate``,
/// `TabManager`, the notification store), so the conforming type is declared in
/// the app target; a lower package cannot name those types. This seam lets the
/// composition root hand the package its ordered set of recorders once and have
/// the package own the install dispatch, instead of the app spelling out one
/// `installIfNeeded()` call per recorder at the launch call site.
///
/// The app builds and caches its recorders (it reuses the same instances from
/// its live notification/navigation hooks), exposes them in launch order through
/// ``launchUITestRecorders``, and calls ``installLaunchUITestRecorders()`` once
/// during `applicationDidFinishLaunching`. Installation is idempotent: every
/// ``UITestRecording/installIfNeeded()`` reads its own `CMUX_UI_TEST_*` gate and
/// carries a one-shot guard, so calling it more than once and on a recorder
/// whose scenario is inactive is a no-op.
///
/// The seam is intentionally `#if DEBUG` only: these recorders exist purely for
/// XCUITest instrumentation and are compiled out of release builds, matching the
/// `#if DEBUG` block they install from.
///
/// Isolation: `@MainActor`, because every recorder reads and mutates main-actor
/// app state during install.
@MainActor
public protocol UITestRecorderInstalling: AnyObject {
    /// The recorders to install at launch, in the order the legacy
    /// `applicationDidFinishLaunching` block installed them.
    ///
    /// The app returns the same cached instances its live hooks write through,
    /// so installing here arms exactly the recorders those hooks later record
    /// into.
    var launchUITestRecorders: [any UITestRecording] { get }
}

extension UITestRecorderInstalling {
    /// Installs every recorder in ``launchUITestRecorders`` in order.
    ///
    /// The owner calls this once at launch; the per-recorder env gate and
    /// one-shot guard make the call a no-op for inactive scenarios and safe to
    /// repeat. Owning the iteration here keeps the install-order decision in one
    /// tested place rather than re-expressed at the launch call site.
    public func installLaunchUITestRecorders() {
        for recorder in launchUITestRecorders {
            recorder.installIfNeeded()
        }
    }
}
#endif
