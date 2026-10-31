public import AppKit

/// A page's right-click menu (webviews `ui/ContextMenu.tsx`) as a standard macOS menu: the page
/// sends its rows and the pointer, the host pops an `NSMenu` up there and answers the chosen row's
/// id, or nil when the menu was dismissed. AppKit draws the background, font, rows, separators and
/// highlight; only a row's icon (`symbol`, an SF Symbol) is the page's (Lawrence 2026-10-23: "we
/// don't want ANYTHING custom besides the icons").
@MainActor
public struct WebContextMenu {
    public struct Row: Equatable {
        public var id: String
        public var label: String
        public var symbol: String?
        public var disabled = false
        public var checked = false
        public var separator = false
    }

    public let rows: [Row]
    /// The pointer, in CSS px in the page's viewport.
    public let point: CGPoint

    /// `{items: [{id, label, symbol?, disabled?, checked?, separator?}], point: {x, y}}`; nil when
    /// malformed or when no row can be chosen.
    public init?(_ params: [String: Any]) {
        guard let items = params["items"] as? [[String: Any]], let point = params["point"] as? [String: Any],
              let x = (point["x"] as? NSNumber)?.doubleValue, let y = (point["y"] as? NSNumber)?.doubleValue else { return nil }
        rows = items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return Row(id: id, label: item["label"] as? String ?? "", symbol: item["symbol"] as? String,
                       disabled: item["disabled"] as? Bool ?? false, checked: item["checked"] as? Bool ?? false,
                       separator: item["separator"] as? Bool ?? false)
        }
        guard rows.contains(where: { !$0.separator }) else { return nil }
        self.point = CGPoint(x: x, y: y)
    }

    /// The menu: one native item per row; a chosen row calls `choose` with its id.
    public func menu(choose: @escaping @MainActor (String) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for row in rows {
            if row.separator {
                // No separator first, last or twice in a row, as AppKit's own menus.
                if menu.numberOfItems > 0, menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
                continue
            }
            let choice = WebContextMenuChoice { choose(row.id) }
            let item = NSMenuItem(title: row.label, action: #selector(WebContextMenuChoice.run), keyEquivalent: "")
            item.target = choice
            item.representedObject = choice
            item.isEnabled = !row.disabled
            item.state = row.checked ? .on : .off
            if let symbol = row.symbol { item.image = NSImage.menuSymbol(symbol) }
            menu.addItem(item)
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.numberOfItems - 1) }
        return menu
    }

    /// Pops the menu up at `point` in `webView` (`zoom`: CSS px to points) on the next turn of the
    /// run loop, so the page call that asked returns first, and calls `done` once with the chosen
    /// row's id, or nil.
    public func present(in webView: NSView, zoom: CGFloat, done: @escaping @MainActor (String?) -> Void) {
        let picked = WebContextMenuPick()
        let shown = menu { picked.id = $0 }
        let local = CGPoint(x: point.x * zoom, y: point.y * zoom)
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak webView] in
            MainActor.assumeIsolated { // main-proof: a CFRunLoopGetMain() block runs on the main thread
                // A view in no window cannot anchor a menu (AppKit raises): dismissed.
                guard let webView, webView.window != nil else { return done(nil) }
                let at = webView.isFlipped ? local : CGPoint(x: local.x, y: webView.bounds.height - local.y)
                shown.popUp(positioning: nil, at: at, in: webView)
                done(picked.id)
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}

/// A row's closure, kept alive as its item's `representedObject` (an item's target is weak).
final class WebContextMenuChoice: NSObject {
    private let body: @MainActor () -> Void

    init(_ body: @escaping @MainActor () -> Void) { self.body = body }

    @objc func run() { body() }
}

/// The row chosen while the menu tracked.
@MainActor final class WebContextMenuPick {
    var id: String?
}
