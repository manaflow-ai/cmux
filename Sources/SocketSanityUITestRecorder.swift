#if DEBUG
import AppKit
import CmuxTestSupport
import Foundation

/// Schedules the `CMUX_UI_TEST_SOCKET_SANITY` socket-readiness check for the
/// socket-sanity XCUITest scenario.
///
/// The recorder owns the live `AppDelegate` it reads the socket listener
/// configuration, transport, and restart hook from, so the conforming type is
/// declared in the app target (a lower package cannot reference `AppDelegate`
/// or the socket internals); the diagnostics capture-file assembly and I/O
/// still live in ``CmuxTestSupport``, which the diagnostics writer drives.
///
/// ``installIfNeeded()`` is gated by `CMUX_UI_TEST_SOCKET_SANITY` and carries a
/// one-shot guard, so it is a no-op for production launches and safe to call
/// more than once. The launch call site only invokes it when the process is
/// running under XCTest or `CMUX_UI_TEST_MODE` is set, matching the legacy
/// `AppDelegate` call site; the inner `CMUX_UI_TEST_SOCKET_SANITY` gate is the
/// recorder's own.
///
/// After a 0.75s delay it probes the listener health and pings the socket,
/// writing `socketSanityReady` when healthy, otherwise writing
/// `socketSanityRestart`, restarting the listener, and writing
/// `socketSanityPostRestart` after another 0.75s. The two `DispatchQueue.main`
/// delays are preserved verbatim from the legacy implementation this was lifted
/// from (faithful lift; the timing is part of the scenario's wire behavior).
@MainActor
final class SocketSanityUITestRecorder: UITestRecording {
    private unowned let appDelegate: AppDelegate
    private let environment: [String: String]
    private var didSchedule = false

    /// - Parameters:
    ///   - appDelegate: The live app delegate whose socket listener and
    ///     transport the recorder probes.
    ///   - environment: The process environment; defaults to the real one.
    init(
        appDelegate: AppDelegate,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.appDelegate = appDelegate
        self.environment = environment
    }

    func installIfNeeded() {
        guard environment["CMUX_UI_TEST_SOCKET_SANITY"] == "1" else { return }
        guard !didSchedule else { return }
        didSchedule = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self else { return }
            guard let config = self.appDelegate.socketListenerConfigurationIfEnabled() else {
                self.appDelegate.writeUITestDiagnosticsIfNeeded(stage: "socketSanityDisabled")
                return
            }

            let terminalControl = self.appDelegate.terminalControl
            let socketTransport = self.appDelegate.socketTransport
            let expectedPath = terminalControl.activeSocketPath(preferredPath: config.path)
            let health = terminalControl.socketListenerHealth(expectedSocketPath: expectedPath)
            let pingResponse = health.isHealthy
                ? socketTransport.probeCommand("ping", at: expectedPath, timeout: 1.0)
                : nil
            let isReady = health.isHealthy && pingResponse == "PONG"
            if isReady {
                self.appDelegate.writeUITestDiagnosticsIfNeeded(stage: "socketSanityReady")
                return
            }

            self.appDelegate.writeUITestDiagnosticsIfNeeded(stage: "socketSanityRestart")
            self.appDelegate.restartSocketListenerIfEnabled(source: "uiTest.socketSanity")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                self?.appDelegate.writeUITestDiagnosticsIfNeeded(stage: "socketSanityPostRestart")
            }
        }
    }
}
#endif
