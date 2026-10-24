import AppKit
import CmuxNextCompat

/// Follows the strip's window becoming and leaving main: only the main
/// window's selected tab is filled (dogfood 2026-10-08, 08). Main, not key,
/// so a dialog or palette panel taking the keyboard leaves the strip as it is.
@MainActor
final class WindowMainObserver {
    private(set) var isMain = true
    private var onChange: (Bool) -> Void = { _ in }
    /// The window's become-main and resign-main observations; each stops when released.
    private var observations: [MainActorObservation] = []

    /// Starts following `window` (nil stops) and reports its current status.
    func observe(_ window: NSWindow?, onChange: @escaping (Bool) -> Void) {
        observations = []
        self.onChange = onChange
        guard let window else { return }
        changed(isMain: window.isMainWindow)
        observations = [
            MainActorObservation(NSWindow.didBecomeMainNotification, object: window) { [weak self] in self?.changed(isMain: true) },
            MainActorObservation(NSWindow.didResignMainNotification, object: window) { [weak self] in self?.changed(isMain: false) },
        ]
    }

    func changed(isMain: Bool) {
        self.isMain = isMain
        onChange(isMain)
    }
}
