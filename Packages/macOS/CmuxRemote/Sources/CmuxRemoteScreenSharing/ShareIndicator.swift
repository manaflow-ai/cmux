// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation

/// The menu bar item while a device sees or controls this Mac, from the
/// Screen Sharing worker (so it shows with the cmux app quit): who and how,
/// Stop Sharing This Mac (ends the session) and Revoke This Device (its
/// access becomes None, which ends the session).
@MainActor
final class ShareIndicator: NSObject {
    private var item: NSStatusItem?
    private(set) var title = ""
    var stop: () -> Void = {}
    var revoke: () -> Void = {}

    func show(_ title: String?) {
        guard let title else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            self.title = ""
            return
        }
        self.title = title
        let item = self.item ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.item = item
        let image = NSImage(systemSymbolName: "display", accessibilityDescription: title)
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = title
        let menu = NSMenu()
        let heading = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())
        let stop = NSMenuItem(title: RemoteText.t("action.macScreen.stopSharing", "Stop Sharing This Mac"), action: #selector(stopPressed), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)
        let revoke = NSMenuItem(title: RemoteText.t("action.macScreen.revokeViewer", "Revoke This Device"), action: #selector(revokePressed), keyEquivalent: "")
        revoke.target = self
        menu.addItem(revoke)
        item.menu = menu
    }

    @objc private func stopPressed() { stop() }
    @objc private func revokePressed() { revoke() }
}
