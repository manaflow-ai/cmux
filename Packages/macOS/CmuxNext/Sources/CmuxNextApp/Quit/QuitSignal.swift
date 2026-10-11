import AppKit
import Darwin

/// SIGTERM, SIGINT and SIGHUP are "Quit, keep sessions" (coordinator
/// decision 2026-10-02): `kill`, dev tooling, Ctrl-C in the terminal that
/// launched the app, or that terminal closing. `SignalRelay` delivers them
/// on the main queue, where the first starts a normal quit with origin
/// `.signal`, which never shows the alert and never ends a terminal
/// (`QuitPolicy`); windows still save and the run marker records the quit
/// (`AppRunMarker.markQuitting`), so the next launch is clean even when the
/// sender escalates to SIGKILL before the quit finishes. A second signal
/// while that quit runs exits at once (`forceExit`), so a stuck quit never
/// holds dev tooling. Before this is installed, `AppRunMarker` records these
/// signals as requested quits and the process ends as it did before.
@MainActor
enum QuitSignal {
    private static var relay: SignalRelay?
    private static var received = 0

    static var isInstalled: Bool { relay != nil }

    static func install(quit: @escaping @MainActor () -> Void, forceExit: @escaping @MainActor () -> Void) {
        guard relay == nil else { return }
        relay = SignalRelay(signals: LaunchRecovery.requestedQuitSignals.sorted()) { _ in
            received += 1
            if received == 1 { quit() } else { forceExit() }
        }
    }

    /// Takes the signals back after Chromium starts, which resets signal
    /// actions and installs its own SIGINT and SIGHUP handlers.
    static func reclaim() {
        relay?.catchSignals()
    }
}
