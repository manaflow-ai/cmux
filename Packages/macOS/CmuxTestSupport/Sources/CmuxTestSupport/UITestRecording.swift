/// A self-installing UI-test instrumentation recorder for one XCUITest
/// scenario.
///
/// Each scenario (goto-split navigation, bonsplit tab-drag, multi-window
/// notifications) records internal app state into a capture file so an
/// XCUITest run can assert on it. A recorder owns the live app references it
/// needs to read that state, so the conforming type is declared in the app
/// target (a lower package cannot reference `AppDelegate`/`TabManager`/
/// `Workspace`); this seam lets the composition root hold and install every
/// recorder uniformly without naming each concrete type.
///
/// ``installIfNeeded()`` is the single entry point the app calls once during
/// `applicationDidFinishLaunching`. It is idempotent: a recorder reads its
/// own `CMUX_UI_TEST_*` environment gates and short-circuits to a no-op when
/// its scenario is not active, so production launches install nothing. The
/// recorder owns its own one-shot guard; calling `installIfNeeded()` more
/// than once is safe.
///
/// Capture-file I/O goes through ``TestCaptureWriting`` so the byte-faithful
/// JSON/line writes and env-gating stay in one tested place; a recorder
/// reads live state on the main actor and hands the resulting values to that
/// sink.
@MainActor
public protocol UITestRecording: AnyObject {
    /// Installs the recorder if its scenario's environment gate is set,
    /// otherwise does nothing. Idempotent across repeated calls.
    func installIfNeeded()
}
