import AppKit
import CmuxNextActions
import CmuxNextDesign

/// The menu bar item shown while a device sees or controls this Mac, or while
/// Share This Mac is on with no device connected: visible from every app. For a
/// session it names who and how (a device hub session) and offers Stop Sharing
/// (ends the session) and, for a device hub session, Revoke This Device (sets
/// its access to None and ends the session); with no session it offers Stop
/// Sharing This Mac. The rows run registered actions (`macScreen.stopSharing`,
/// `macScreen.revokeViewer`, `macScreen.stopSharingThisMac`), the same path as
/// the palette and `cmux action run`.
@MainActor
final class MacScreenShareIndicator: NSObject {
    static let stopSharingAction: ActionID = "macScreen.stopSharing"
    static let revokeViewerAction: ActionID = "macScreen.revokeViewer"
    static let stopSharingThisMacAction: ActionID = "macScreen.stopSharingThisMac"

    private var item: NSStatusItem?
    /// The in-app host bar is the first-class stop affordance. The menu bar item remains as a
    /// compact fallback for hosts that are covered by a full-screen app.
    /// Created only when a viewer connects; headless launches do not create an extra panel.
    private var bar: MacScreenSharingBar?
    /// The registry's row for an action (`ActionRegistry.makeMenuItem`); the app sets it.
    var menuItem: (ActionID) -> NSMenuItem? = { _ in nil }
    /// Whether the session shown offers Revoke This Device.
    private(set) var offersRevoke = false
    /// A device is connected now; false: Share This Mac is on with no session, and the row turns it off.
    private(set) var sessionLive = true
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
            // `update(title:)` stages the content and presents the bar after the title is ready.
        } else if !visible, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
            bar?.hide()
            bar = nil
        }
    }

    /// Shows `title` (who, and View Only or Full Control) from now on.
    func update(title: String, offersRevoke: Bool, sessionLive: Bool = true) {
        self.title = title
        self.offersRevoke = offersRevoke
        self.sessionLive = sessionLive
        // The bar is for a live session; shared with no one connected shows only the menu bar item.
        if sessionLive {
            let bar = bar ?? {
                let created = MacScreenSharingBar()
                self.bar = created
                return created
            }()
            bar.update(title: title) { [weak self] in self?.run(Self.stopSharingAction) }
            bar.show()
        } else {
            bar?.hide()
            bar = nil
        }
        rebuild()
    }

    /// The menu's action rows, in order.
    var rowActions: [ActionID] { Self.rowActions(sessionLive: sessionLive, offersRevoke: offersRevoke) }

    /// The rows for a live session (Stop Sharing, and Revoke This Device when offered), or, shared with
    /// no device connected, Stop Sharing This Mac (turns Share This Mac off).
    static func rowActions(sessionLive: Bool, offersRevoke: Bool) -> [ActionID] {
        guard sessionLive else { return [stopSharingThisMacAction] }
        return offersRevoke ? [stopSharingAction, revokeViewerAction] : [stopSharingAction]
    }

    /// The sharing bar is up (a live session only).
    var showsBar: Bool { bar != nil }

    /// Runs the same registered action as the menu item. This keeps the one-click bar on the
    /// app's action path (and therefore the CLI and palette path) instead of duplicating teardown.
    private func run(_ action: ActionID) {
        guard let item = menuItem(action), let target = item.target, let selector = item.action else { return }
        _ = NSApp.sendAction(selector, to: target, from: item)
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
        for id in rowActions {
            if let row = menuItem(id) { menu.addItem(row) }
        }
        item.menu = menu
    }
}
