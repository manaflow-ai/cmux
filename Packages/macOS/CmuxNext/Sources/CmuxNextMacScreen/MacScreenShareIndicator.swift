import AppKit

/// The menu bar item shown while a device sees or controls this Mac: visible
/// from every app. It names who and how (a device hub session) and offers
/// Stop Sharing (ends the session) and, for a device hub session, Revoke
/// This Device (sets its access to None and ends the session).
@MainActor
final class MacScreenShareIndicator: NSObject {
    private var item: NSStatusItem?
    var stopSharing: () -> Void = {}
    /// Set while a device hub session shows: Revoke This Device.
    var revokeDevice: (() -> Void)?
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
    func update(title: String, revoke: (() -> Void)?) {
        self.title = title
        revokeDevice = revoke
        rebuild()
    }

    private func rebuild() {
        guard let item else { return }
        item.button?.toolTip = title
        item.button?.image?.accessibilityDescription = title
        let menu = NSMenu()
        let heading = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())
        let stop = NSMenuItem(title: L.t("macScreen.indicator.stop", "Stop Sharing This Mac"), action: #selector(stopPressed), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)
        if revokeDevice != nil {
            let revoke = NSMenuItem(title: L.t("macScreen.indicator.revoke", "Revoke This Device"), action: #selector(revokePressed), keyEquivalent: "")
            revoke.target = self
            menu.addItem(revoke)
        }
        item.menu = menu
    }

    @objc private func stopPressed() { stopSharing() }
    @objc private func revokePressed() { revokeDevice?() }
}
