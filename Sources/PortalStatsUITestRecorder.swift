#if DEBUG
import AppKit
import CmuxTestSupport
import Foundation

/// Installs the `CMUX_UI_TEST_PORTAL_STATS` diagnostics observer for the
/// portal-stats XCUITest scenario.
///
/// The recorder owns the live `AppDelegate` it writes diagnostics through, so
/// the conforming type is declared in the app target (a lower package cannot
/// reference `AppDelegate`); the capture-file assembly and I/O still live in
/// ``CmuxTestSupport``, which the diagnostics writer drives. ``installIfNeeded()``
/// is gated by `CMUX_UI_TEST_PORTAL_STATS` and carries a one-shot guard, so it
/// is a no-op for production launches and safe to call more than once.
///
/// On install it subscribes to the terminal portal-visibility notification,
/// writing the `feedSidebarUITest.terminalPortalVisibilityDidChange` stage on
/// each change, and writes an initial `feedSidebarUITest.portalStats.setup`
/// stage. The recorder retains the observer token for the process lifetime,
/// matching the legacy `AppDelegate` implementation this was lifted from (the
/// legacy code kept it in an `AppDelegate` array that was never torn down).
@MainActor
final class PortalStatsUITestRecorder: UITestRecording {
    private unowned let appDelegate: AppDelegate
    private let environment: [String: String]
    private var didSetup = false
    private var observers: [NSObjectProtocol] = []

    /// - Parameters:
    ///   - appDelegate: The live app delegate the recorder writes diagnostics
    ///     stages through.
    ///   - environment: The process environment; defaults to the real one.
    init(
        appDelegate: AppDelegate,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.appDelegate = appDelegate
        self.environment = environment
    }

    func installIfNeeded() {
        guard environment["CMUX_UI_TEST_PORTAL_STATS"] == "1" else { return }
        guard !didSetup else { return }
        didSetup = true

        let observer = NotificationCenter.default.addObserver(
            forName: .terminalPortalVisibilityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.appDelegate.writeUITestDiagnosticsIfNeeded(stage: "feedSidebarUITest.terminalPortalVisibilityDidChange")
            }
        }
        observers.append(observer)
        appDelegate.writeUITestDiagnosticsIfNeeded(stage: "feedSidebarUITest.portalStats.setup")
    }
}
#endif
