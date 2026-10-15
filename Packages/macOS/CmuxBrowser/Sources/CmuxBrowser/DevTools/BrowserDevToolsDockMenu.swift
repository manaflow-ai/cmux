import AppKit

/// The DevTools dock-side menu: Dock to Left, Dock to Bottom, Dock to Right, Undock into Separate
/// Window, then Close Developer Tools. The current side has a checkmark. Chrome's DevTools offer
/// the same four placements under "Dock side".
@MainActor
struct BrowserDevToolsDockMenu {
    let controller: BrowserDevToolsPaneController

    /// The dock choices in menu order with their titles.
    static var choices: [(dock: BrowserDevToolsDock, title: String)] {
        [
            (.left, String(localized: "browser.devTools.dockLeft", defaultValue: "Dock to Left", bundle: .module)),
            (.bottom, String(localized: "browser.devTools.dockBottom", defaultValue: "Dock to Bottom", bundle: .module)),
            (.right, String(localized: "browser.devTools.dockRight", defaultValue: "Dock to Right", bundle: .module)),
            (.window, String(localized: "browser.devTools.undock", defaultValue: "Undock into Separate Window", bundle: .module)),
        ]
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let current = controller.state.dock
        for choice in Self.choices {
            let item = BrowserMenuActionTarget.item(title: choice.title) { [weak controller] in
                controller?.perform(.dock(choice.dock))
            }
            item.state = choice.dock == current ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let closeTitle = String(localized: "browser.devTools.close", defaultValue: "Close Developer Tools", bundle: .module)
        menu.addItem(BrowserMenuActionTarget.item(title: closeTitle) { [weak controller] in
            controller?.perform(.close)
        })
        return menu
    }
}
