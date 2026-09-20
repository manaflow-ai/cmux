import AppKit
import CmuxAppKitSupportUI
import SwiftUI

#if DEBUG
/// A design-review panel owned by the application's debug-window coordinator.
@MainActor
final class CloudAnnouncementPreviewWindowController: ReleasingWindowController {
    private weak var decorator: (any WindowDecorating)?
    private let defaults: UserDefaults

    init(decorator: (any WindowDecorating)?, defaults: UserDefaults) {
        self.decorator = decorator
        self.defaults = defaults
        super.init()
    }

    override func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "debug.cloudAnnouncement.title", defaultValue: "Cloud Announcement")
        window.identifier = NSUserInterfaceItemIdentifier("cmux.cloudAnnouncementPreview")
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(
            rootView: CloudAnnouncementPreviewControls().defaultAppStorage(defaults)
        )
        window.center()
        decorator?.applyWindowDecorations(to: window)
        return window
    }

    func show() {
        defaults.set(true, forKey: CloudAnnouncementPreviewStyle.visibilityKey)
        showManagedWindow(activateApplication: true)
    }
}
#endif
