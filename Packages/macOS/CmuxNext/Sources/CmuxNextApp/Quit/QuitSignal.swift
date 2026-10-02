import AppKit
import Darwin

/// SIGTERM is "Quit, keep sessions" (coordinator decision 2026-10-02): the
/// signal is ignored as a process signal and delivered on the main queue,
/// where it starts a normal quit with origin `.signal`, which never shows
/// the alert and never ends a terminal (`QuitPolicy`); windows still save.
/// A second SIGTERM while that quit runs exits at once (`forceExit`), so a
/// stuck quit never holds dev tooling, which sends SIGKILL after a bounded
/// wait anyway. Before this is installed, `AppRunMarker` records SIGTERM
/// as a requested quit and the process ends as it did before.
@MainActor
enum QuitSignal {
    private static var source: (any DispatchSourceSignal)?
    private static var received = 0

    static var isInstalled: Bool { source != nil }

    static func install(quit: @escaping @MainActor () -> Void, forceExit: @escaping @MainActor () -> Void) {
        guard source == nil else { return }
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                received += 1
                if received == 1 { quit() } else { forceExit() }
            }
        }
        source.resume()
        Self.source = source
        ignoreProcessSignal()
    }

    /// Keeps SIGTERM from ending the process so the source sees it. Called
    /// again after Chromium starts, which resets signal actions.
    static func ignoreProcessSignal() {
        guard source != nil else { return }
        _ = Darwin.signal(SIGTERM, SIG_IGN)
    }
}
