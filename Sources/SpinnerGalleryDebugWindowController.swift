#if DEBUG
import AppKit
import SwiftUI

/// Debug-only spinner comparison window (Debug → Debug Windows → Spinner
/// Gallery…). Strings are English-only by design: the file is `#if DEBUG`,
/// matching the other debug windows.
final class SpinnerGalleryDebugWindowController: ReleasingWindowController {
    static let shared = SpinnerGalleryDebugWindowController()

    override func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Spinner Gallery"
        window.identifier = NSUserInterfaceItemIdentifier("cmux.spinnerGallery")
        window.minSize = NSSize(width: 420, height: 480)
        // Float above the workspace windows so frame-capture screenshots reliably
        // target this window (the debug screenshot picks key/main/largest, and
        // the restored terminal window would otherwise win as main).
        window.level = .floating
        window.center()
        window.contentView = NSHostingView(rootView: SpinnerGalleryRootView())
        return window
    }

    func show() {
        showManagedWindow(activateApplication: true, orderFrontRegardless: true)
        window?.makeKey()
    }
}
#endif
