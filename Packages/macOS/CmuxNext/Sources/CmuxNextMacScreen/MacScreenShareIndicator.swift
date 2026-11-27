import AppKit
import CmuxNextActions
import CmuxNextDesign

/// The menu bar item shown while a device sees or controls this Mac: visible
/// from every app. It names who and how (a device hub session) and offers
/// Stop Sharing (ends the session) and, for a device hub session, Revoke
/// This Device (sets its access to None and ends the session). Both rows run
/// registered actions (`macScreen.stopSharing`, `macScreen.revokeViewer`), the
/// same path as the palette and `cmux action run`. While sharing an owner's agent turned on
/// is on with no viewer, it says so (who turned it on, and that it turns itself off) and offers
/// Stop Sharing This Mac (`macScreen.stopSharingThisMac`): no silent sharing.
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
    /// Whether the menu offers Stop Sharing This Mac (an agent's share with no viewer).
    private(set) var offersTurnOff = false
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
    func update(title: String, offersRevoke: Bool, offersTurnOff: Bool = false) {
        self.title = title
        self.offersRevoke = offersRevoke
        self.offersTurnOff = offersTurnOff
        let bar = bar ?? {
            let created = MacScreenSharingBar()
            self.bar = created
            return created
        }()
        // The bar's Stop is the menu's: an agent's share with no viewer ends Share This Mac.
        let stop = offersTurnOff ? Self.stopSharingThisMacAction : Self.stopSharingAction
        bar.update(title: title) { [weak self] in self?.run(stop) }
        bar.show()
        rebuild()
    }

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
        if offersTurnOff, let turnOff = menuItem(Self.stopSharingThisMacAction) {
            menu.addItem(turnOff)
        } else if let stop = menuItem(Self.stopSharingAction) {
            menu.addItem(stop)
        }
        if offersRevoke, let revoke = menuItem(Self.revokeViewerAction) {
            menu.addItem(revoke)
        }
        item.menu = menu
    }
}
