import AppKit

/// The menu bar item shown while a device sees and controls this Mac
/// (Share This Mac): visible from every app, with Stop Sharing (which also disconnects).
@MainActor
final class MacScreenShareIndicator: NSObject {
    private var item: NSStatusItem?
    var stopSharing: () -> Void = {}

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let image = NSImage(systemSymbolName: "display", accessibilityDescription: L.t("macScreen.indicator.title", "This Mac is being controlled"))
            image?.isTemplate = true
            item.button?.image = image
            item.button?.toolTip = L.t("macScreen.indicator.title", "This Mac is being controlled")
            let menu = NSMenu()
            let title = NSMenuItem(title: L.t("macScreen.indicator.title", "This Mac is being controlled"), action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            menu.addItem(.separator())
            let stop = NSMenuItem(title: L.t("macScreen.indicator.stop", "Stop Sharing This Mac"), action: #selector(stopPressed), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
            item.menu = menu
            self.item = item
        } else if !visible, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    @objc private func stopPressed() { stopSharing() }
}
