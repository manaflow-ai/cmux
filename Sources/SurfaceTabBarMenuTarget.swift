import AppKit
import Bonsplit

/// Target object for surface tab bar `NSMenuItem`s. Kept alive by the
/// workspace while its menu is open; forwards picked items back to the
/// workspace for execution.
final class SurfaceTabBarMenuTarget: NSObject {
    weak var workspace: Workspace?
    let pane: PaneID

    init(workspace: Workspace, pane: PaneID) {
        self.workspace = workspace
        self.pane = pane
    }

    @MainActor @objc func performMenuItem(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? SurfaceTabBarMenuItemPayload else { return }
        workspace?.executeSurfaceTabBarExecutableButton(payload.item, inPane: pane)
    }
}
