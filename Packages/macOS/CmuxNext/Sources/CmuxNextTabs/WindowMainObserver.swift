import AppKit

/// Follows the strip's window becoming and leaving main: only the main
/// window's selected tab is filled (dogfood 2026-10-08, 08). Main, not key,
/// so a dialog or palette panel taking the keyboard leaves the strip as it is.
@MainActor
final class WindowMainObserver {
    private(set) var isMain = true
    private var onChange: (Bool) -> Void = { _ in }
    private var observers: [NSObjectProtocol] = []

    /// Starts following `window` (nil stops) and reports its current status.
    func observe(_ window: NSWindow?, onChange: @escaping (Bool) -> Void) {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        self.onChange = onChange
        guard let window else { return }
        changed(isMain: window.isMainWindow)
        observers = [NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                let isMain = note.name == NSWindow.didBecomeMainNotification
                // main-proof: the observer runs on the main queue (queue: .main)
                MainActor.assumeIsolated { self?.changed(isMain: isMain) }
            }
        }
    }

    func changed(isMain: Bool) {
        self.isMain = isMain
        onChange(isMain)
    }
}
