public import AppKit

/// Keeps a closure alive as an `NSMenuItem`'s target. The item holds it as its
/// `representedObject`, since a menu item's target is weak.
@MainActor
public final class BrowserMenuActionTarget: NSObject {
    private let body: () -> Void

    /// Creates a target running `body`.
    /// - Parameter body: What choosing the item does.
    public init(_ body: @escaping () -> Void) {
        self.body = body
    }

    /// The menu item action.
    @objc public func run(_ sender: Any?) {
        body()
    }

    /// Makes an enabled menu item that runs `body` when chosen.
    /// - Parameters:
    ///   - title: The item title.
    ///   - body: What choosing the item does.
    /// - Returns: The item, retaining its target.
    public static func item(title: String, _ body: @escaping () -> Void) -> NSMenuItem {
        let target = BrowserMenuActionTarget(body)
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        item.isEnabled = true
        return item
    }

    /// The target of `item` if it was made by ``item(title:_:)``.
    /// - Parameter item: A menu item.
    /// - Returns: The target, or `nil`.
    public static func target(of item: NSMenuItem) -> BrowserMenuActionTarget? {
        item.representedObject as? BrowserMenuActionTarget
    }
}
