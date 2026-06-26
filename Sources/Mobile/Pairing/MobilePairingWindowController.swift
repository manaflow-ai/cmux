import AppKit
import SwiftUI

/// Owns the single iOS pairing window and presents it on demand.
///
/// Mirrors the host-side config window pattern: it reuses the existing window
/// when one is already open (so repeated requests focus instead of spawning
/// duplicates) and hosts ``MobilePairingView`` in an `NSHostingController`.
@MainActor
final class MobilePairingWindowController: ReleasingWindowController {
    /// The shared controller. The app target composes window controllers as
    /// singletons (see the task-manager and debug windows).
    static let shared = MobilePairingWindowController()

    /// The pairing window's identifier. Listed in
    /// `AuxiliaryWindowRegistry.default` (CmuxFoundation) so the standard close
    /// shortcut closes this window instead of a terminal tab in the main
    /// window behind it; referenced from the Cmd+W regression test.
    static let windowIdentifier = "cmux.mobilePairingWindow"

    private override init() {
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Brings the pairing window to the front, creating it if needed.
    func show() {
        NSApp.activate(ignoringOtherApps: true)

        let window = managedWindow()
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    override func makeWindow() -> NSWindow {
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
        // Tall enough that the title, the manual-entry block, and the whole QR
        // are visible without scrolling out of the box; the 540x720 default
        // clipped the heading and pushed Copy IP/Port below the fold in
        // dogfood. The minimum keeps the QR plus the manual block usable on
        // small screens.
        window.setContentSize(NSSize(width: 560, height: 800))
        window.contentMinSize = NSSize(width: 480, height: 600)
        window.center()
        return window
    }
}
