import AppKit
import SwiftUI

extension AppDelegate {
    func showCloudDiagnostics() {
        guard let cloudOperations else { return }
        if let controller = cloudDiagnosticsWindowController {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = String(localized: "cloud.diagnostics.title", defaultValue: "Cloud Diagnostics")
        window.identifier = NSUserInterfaceItemIdentifier("CloudDiagnosticsWindow")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CloudDiagnosticsView(recorder: cloudOperations))
        window.center()
        let controller = NSWindowController(window: window)
        cloudDiagnosticsWindowController = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}
