import AppKit
import CmuxNextActions
import CmuxNextDesign

/// The menu bar item shown while a device sees or controls this Mac: visible
/// from every app. It names who and how (a device hub session) and offers
/// Stop Sharing (ends the session) and, for a device hub session, Revoke
/// This Device (sets its access to None and ends the session). Both rows run
/// registered actions (`macScreen.stopSharing`, `macScreen.revokeViewer`), the
/// same path as the palette and `cmux action run`.
@MainActor
final class MacScreenShareIndicator: NSObject {
    static let stopSharingAction: ActionID = "macScreen.stopSharing"
    static let revokeViewerAction: ActionID = "macScreen.revokeViewer"

    private var item: NSStatusItem?
    /// The registry's row for an action (`ActionRegistry.makeMenuItem`); the app sets it.
    var menuItem: (ActionID) -> NSMenuItem? = { _ in nil }
    /// Whether the session shown offers Revoke This Device.
    private(set) var offersRevoke = false
    /// The menu's first line: who sees or controls this Mac.
    private(set) var title = MacScreenShareIndicator.defaultTitle

    static var defaultTitle: String { L.t("macScreen.indicator.title", "This Mac is being controlled") }

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let image = NSImage(systemSymbolName: "display", accessibilityDescription: title)
            image?.isTemplate = true
            item.button?.image = image
            self.item = item
            rebuild()
        } else if !visible, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    /// Shows `title` (who, and View Only or Full Control) from now on.
    func update(title: String, offersRevoke: Bool) {
        self.title = title
        self.offersRevoke = offersRevoke
        rebuild()
    }

    private func rebuild() {
        guard let item else { return }
        // Who sees or controls this Mac, on hover too: a themed tip, never the stock bubble.
        item.button?.themedToolTip = title
        item.button?.image?.accessibilityDescription = title
        let menu = NSMenu()
        let heading = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())
        if let stop = menuItem(Self.stopSharingAction) {
            menu.addItem(stop)
        }
        if offersRevoke, let revoke = menuItem(Self.revokeViewerAction) {
            menu.addItem(revoke)
        }
        item.menu = menu
    }
}
