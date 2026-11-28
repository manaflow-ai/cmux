#if DEBUG
public import AppKit

/// DEBUG ONLY: the UI shell's Mac Screen scene (Prototypes/UiLayerHost `cmux-ui-macscreen --shoot DIR`, scene
/// `mac-screen-sharing`): the real Screen Sharing page in a window of its own, sharing on and both macOS permissions
/// allowed (the sharing gallery's "ready" state, AAMacScreenSharingGalleryTests), so a push to this module gets a
/// before and after look without an app build. Sample state only: it starts no sharing.
@MainActor
public final class MacScreenScenePlayground {
    private var window: NSWindow?

    public init() {}

    /// Opens the window, or raises the open one.
    public func show() {
        let window = window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    static let snapshot = MacScreenHomeSnapshot(
        sharing: .init(isSharing: true, busy: false, screenRecordingGranted: true, accessibilityGranted: true,
                       session: nil, lastError: nil),
        keyboard: .init(enabled: false, needsAccessibility: false), sharingLook: .list)

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 640), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Mac Screen Playground"
        window.isReleasedWhenClosed = false
        let home = MacScreenHomeView(host: MacScreenShareHost(), actions: MacScreenHomeActions())
        home.autoresizingMask = [.width, .height]
        window.contentView = home
        home.resolveColors()
        home.build(Self.snapshot)
        home.layoutPage()
        window.center()
        return window
    }
}
#endif
