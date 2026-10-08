public import AppKit

/// Turns an engine's context menu model into an `NSMenu` and shows it. The
/// host may put its own items (cmux actions) before and after the engine's.
public final class BrowserContextMenuBuilder {
    /// The process-wide presenter used by default browser hosts and diagnostics.
    public static let shared = BrowserContextMenuBuilder()

    /// Creates a presenter whose open menu can be inspected by its host.
    public init() {}

    /// The page menu while it is open (diagnostics: `debug.menu`).
    public private(set) weak var presentedMenu: NSMenu?

    /// Menu items for `request.items`; choosing one completes the request
    /// with its id.
    public func items(for request: BrowserContextMenuRequest) -> [NSMenuItem] {
        request.items.map { item(for: $0, request: request) }
    }

    /// Shows `leading`, the engine's items and `extra` at the request's location in
    /// `view` (the tab's content view) on the next run-loop turn, and
    /// returns at once: the engine asks from inside its own work (a CEF
    /// pump pass), and a menu's tracking loop there would stop all of
    /// Chromium while the menu is open. The request completes when the menu
    /// closes (nil when nothing was chosen).
    public func present(_ request: BrowserContextMenuRequest, in view: NSView, leading: [NSMenuItem] = [], extra: [NSMenuItem] = []) {
        // The engine shows its own menu (WebKit): the rows go into it.
        if let insert = request.insertLeading { return insert(leading) }
        // A background tab's view is in no window; AppKit cannot anchor a
        // menu there (it raises). Dismiss the request instead.
        guard view.window != nil else { return request.complete(nil) }
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak view] in
            MainActor.assumeIsolated {
                guard let view, view.window != nil else { return request.complete(nil) }
                self.show(request, in: view, leading: leading, extra: extra)
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private func show(_ request: BrowserContextMenuRequest, in view: NSView, leading: [NSMenuItem], extra: [NSMenuItem]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in leading { menu.addItem(item) }
        let engine = items(for: request)
        if !leading.isEmpty, !engine.isEmpty { menu.addItem(.separator()) }
        for item in engine { menu.addItem(item) }
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

    private func item(for model: BrowserContextMenuItem, request: BrowserContextMenuRequest) -> NSMenuItem {
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
