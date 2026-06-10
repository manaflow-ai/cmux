import AppKit
import SwiftUI

/// Owns the single iOS pairing window and presents it on demand.
///
/// Mirrors the host-side config window pattern: it reuses the existing window
/// when one is already open (so repeated requests focus instead of spawning
/// duplicates) and hosts ``MobilePairingView`` in an `NSHostingController`.
@MainActor
final class MobilePairingWindowController {
    /// The shared controller. The app target composes window controllers as
    /// singletons (see the task-manager and debug windows).
    static let shared = MobilePairingWindowController()

    private static let windowIdentifier = "cmux.mobilePairingWindow"

    private var window: NSWindow?

    private init() {}

    /// Brings the pairing window to the front, creating it if needed.
    func show() {
        NSApp.activate(ignoringOtherApps: true)

        if let existing = existingWindow() {
            if existing.isMiniaturized {
                existing.deminiaturize(nil)
            }
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            return
        }

        let appearanceMode = UserDefaults.standard.string(forKey: AppearanceSettings.appearanceModeKey)
        let root = MobilePairingView()
            .cmuxAppearanceColorScheme(appearanceMode)
        let hostingController = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hostingController)
        window.title = String(localized: "mobile.pairing.window.title", defaultValue: "Pair iPhone")
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        // Resizable so the QR (which fills the window width) can be made even
        // larger for scanning at a distance.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 460, height: 640))
        window.contentMinSize = NSSize(width: 380, height: 480)
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func existingWindow() -> NSWindow? {
        if let window, window.isVisible || window.isMiniaturized {
            return window
        }
        return NSApp.windows.first {
            $0.identifier?.rawValue == Self.windowIdentifier && ($0.isVisible || $0.isMiniaturized)
        }
    }
}
