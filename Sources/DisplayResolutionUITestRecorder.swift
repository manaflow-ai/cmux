#if DEBUG
import AppKit
import CmuxTestSupport
import Foundation

/// Installs the `CMUX_UI_TEST_DISPLAY_RENDER_STATS` diagnostics observers for
/// the display-resolution XCUITest scenario.
///
/// The recorder owns the live `AppDelegate` it writes diagnostics through, so
/// the conforming type is declared in the app target (a lower package cannot
/// reference `AppDelegate`); the capture-file assembly and I/O still live in
/// ``CmuxTestSupport`` behind ``AppDelegate/currentUITestDiagnosticsSnapshot(environment:)``,
/// which the diagnostics writer drives. ``installIfNeeded()`` is gated by
/// `CMUX_UI_TEST_DISPLAY_RENDER_STATS` and carries a one-shot guard, so it is a
/// no-op for production launches and safe to call more than once.
///
/// On install it subscribes to the window resize / move / screen-change /
/// backing-change notifications plus the terminal surface-ready and
/// portal-visibility notifications, writing the diagnostics stage on each, and
/// writes an initial `displayUITest.setup` stage. The recorder retains the
/// observer tokens for the process lifetime, matching the legacy `AppDelegate`
/// implementation this was lifted from (the legacy code kept them in an
/// `AppDelegate` array that was never torn down).
@MainActor
final class DisplayResolutionUITestRecorder: UITestRecording {
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
        guard environment["CMUX_UI_TEST_DISPLAY_RENDER_STATS"] == "1" else { return }
        guard !didSetup else { return }
        didSetup = true

        let center = NotificationCenter.default
        let observe: (Notification.Name, String) -> Void = { [weak self] name, stage in
            guard let self else { return }
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.appDelegate.writeUITestDiagnosticsIfNeeded(stage: stage)
                }
            }
            self.observers.append(observer)
        }

        observe(NSWindow.didResizeNotification, "displayUITest.windowDidResize")
        observe(NSWindow.didMoveNotification, "displayUITest.windowDidMove")
        observe(NSWindow.didChangeScreenNotification, "displayUITest.windowDidChangeScreen")
        observe(NSWindow.didChangeBackingPropertiesNotification, "displayUITest.windowDidChangeBacking")
        observe(.terminalSurfaceDidBecomeReady, "displayUITest.terminalSurfaceDidBecomeReady")
        observe(.terminalPortalVisibilityDidChange, "displayUITest.terminalPortalVisibilityDidChange")

        appDelegate.writeUITestDiagnosticsIfNeeded(stage: "displayUITest.setup")
    }
}
#endif
