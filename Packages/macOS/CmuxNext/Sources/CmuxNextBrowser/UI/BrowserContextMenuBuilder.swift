public import AppKit

/// Turns an engine's context menu model into an `NSMenu` and shows it. The
/// host may append its own items (cmux actions) after the engine's.
public enum BrowserContextMenuBuilder {
    /// The page menu while it is open (diagnostics: `debug.menu`).
    public private(set) static weak var presentedMenu: NSMenu?

    /// Menu items for `request.items`; choosing one completes the request
    /// with its id.
    public static func items(for request: BrowserContextMenuRequest) -> [NSMenuItem] {
        request.items.map { item(for: $0, request: request) }
    }

    /// Shows the engine's items plus `extra` at the request's location in
    /// `view` (the tab's content view). Runs the menu's tracking loop and
    /// completes the request afterwards (nil when nothing was chosen).
    public static func present(_ request: BrowserContextMenuRequest, in view: NSView, extra: [NSMenuItem] = []) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items(for: request) { menu.addItem(item) }
        if !extra.isEmpty {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            for item in extra { menu.addItem(item) }
        }
        let point = view.isFlipped ? request.location : CGPoint(x: request.location.x, y: view.bounds.height - request.location.y)
        presentedMenu = menu
        menu.popUp(positioning: nil, at: point, in: view)
        presentedMenu = nil
        // An engine item's action already completed the request; this ends
        // a dismissed menu (or one where a host item ran).
        request.complete(nil)
    }

    private static func item(for model: BrowserContextMenuItem, request: BrowserContextMenuRequest) -> NSMenuItem {
        if model.kind == .separator { return .separator() }
        let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: "")
        item.isEnabled = model.isEnabled
        item.state = (model.kind == .check || model.kind == .radio) && model.isChecked ? .on : .off
        if model.kind == .submenu {
            let submenu = NSMenu(title: model.title)
            submenu.autoenablesItems = false
            for child in model.children { submenu.addItem(self.item(for: child, request: request)) }
            item.submenu = submenu
        } else {
            let target = ClosureMenuTarget { [weak request] in request?.complete(model.id) }
            item.target = target
            item.action = #selector(ClosureMenuTarget.run)
            item.representedObject = target
        }
        return item
    }
}

/// Keeps a closure alive as a menu item's target (`representedObject`).
final class ClosureMenuTarget: NSObject {
    private let body: () -> Void

    init(_ body: @escaping () -> Void) {
        self.body = body
    }

    @objc func run() { body() }
}
