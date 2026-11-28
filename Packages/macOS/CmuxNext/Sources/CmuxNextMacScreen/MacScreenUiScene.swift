#if DEBUG
public import AppKit

/// DEBUG ONLY: the UI shell's MacScreen scene (Prototypes/UiLayerHost `cmux-ui-screen --shoot DIR --scene
/// mac-screen-home`, goal auto-ui-preview-under-60s): the real Screen Sharing page (``MacScreenHomeView``) in two
/// windows, a device viewing this Mac and both permissions missing, the states AAMacScreenSharingGalleryTests draws.
/// A push to CmuxNextMacScreen gets its before and after from these, built without the app.
@MainActor
public struct MacScreenUiScene {
    public init() {}
    static let viewing = MacScreenHomeSnapshot.Sharing(
        isSharing: true, busy: false, screenRecordingGranted: true, accessibilityGranted: true,
        session: .init(id: "s1", viewerID: "v1", viewerName: "Studio", scope: .view, connected: true), lastError: nil)
    static let missing = MacScreenHomeSnapshot.Sharing(
        isSharing: true, busy: false, screenRecordingGranted: false, accessibilityGranted: false, session: nil,
        lastError: nil)
    static let devices: [MacScreenHomeSnapshot.Device] = [
        .init(id: "dev-work-mac", name: "Work Mac", isPhone: false, online: false, macScreenShared: true,
              access: MacScreenAccess(.ask)),
        .init(id: "dev-studio", name: "Studio", isPhone: false, online: true, macScreenShared: true,
              access: MacScreenAccess(.ask)),
    ]

    /// Opens the scene's windows (each a new window: the shooter draws every window a scene opens) and returns what
    /// the caller keeps alive for the shot.
    public static func show() -> [AnyObject] {
        var held: [AnyObject] = []
        for (title, sharing) in [("Viewing", viewing), ("Permissions missing", missing)] {
            let snapshot = MacScreenHomeSnapshot(devices: .list(devices), sharing: sharing,
                                                 keyboard: .init(enabled: false, needsAccessibility: false),
                                                 sharingLook: MacScreenTunables.sharingLook.value)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 640), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.title = "Screen Sharing: \(title)"
            window.isReleasedWhenClosed = false
            let home = MacScreenHomeView(host: MacScreenShareHost(), actions: MacScreenHomeActions())
            home.frame = NSRect(x: 0, y: 0, width: 720, height: 640)
            home.autoresizingMask = [.width, .height]
            window.contentView = home
            window.orderFrontRegardless()
            home.resolveColors()
            home.build(snapshot)
            home.layoutPage()
            held.append(window)
        }
        return held
    }
}
#endif
