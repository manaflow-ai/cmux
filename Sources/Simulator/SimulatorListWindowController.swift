#if DEBUG
import AppKit
import SwiftUI

/// Debug-only window that lists installed iOS simulators, lets you boot
/// or shut them down, and previews the framebuffer of a booted device.
/// Open via Debug → Debug Windows → iOS Simulators…
final class SimulatorListWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SimulatorListWindowController()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "simulator.window.title", defaultValue: "iOS Simulators")
        window.identifier = NSUserInterfaceItemIdentifier("cmux.simulators")
        window.minSize = NSSize(width: 520, height: 360)
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: SimulatorListView())
    }

    func show() {
        if window?.isVisible != true {
            window?.center()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
#endif
