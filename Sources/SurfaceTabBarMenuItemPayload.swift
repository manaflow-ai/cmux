import AppKit

/// `representedObject` payload attached to surface tab bar `NSMenuItem`s,
/// carrying the executable button to run when the item is picked.
final class SurfaceTabBarMenuItemPayload: NSObject {
    let item: Workspace.SurfaceTabBarExecutableButton

    init(item: Workspace.SurfaceTabBarExecutableButton) {
        self.item = item
    }
}
