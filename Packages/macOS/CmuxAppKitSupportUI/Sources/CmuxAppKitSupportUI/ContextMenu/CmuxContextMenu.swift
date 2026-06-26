import AppKit

/// An `NSMenu` built on demand from ``CmuxContextMenuElement`` values.
///
/// This is the cmux-side replacement for SwiftUI's `.contextMenu` on high-churn
/// list rows. SwiftUI's `.contextMenu` modifier leaks a
/// `ContextMenuResponder ⇄ AppKitMenuDelegate` pair per attachment
/// (https://github.com/manaflow-ai/cmux/issues/5953); building a plain `NSMenu`
/// only when the user right-clicks avoids creating that responder at all.
///
/// Internal implementation detail of ``AppKitContextMenuCaptureView``; exposed
/// to the test target through `@testable import`.
final class CmuxContextMenu: NSMenu {
    /// Strong references to the action targets, since `NSMenuItem.target` is weak.
    private var actionTargets: [CmuxContextMenuActionTarget] = []

    /// Builds a menu from the supplied elements. Pure and synchronous so it can
    /// be unit-tested without presenting any UI.
    ///
    /// Leading, trailing, and consecutive separators are suppressed so the menu
    /// matches SwiftUI's `.contextMenu` behavior (plain `NSMenu` keeps them).
    convenience init(from elements: [CmuxContextMenuElement]) {
        self.init(title: "")
        // Honor each item's `isEnabled` exactly instead of letting AppKit
        // auto-enable/disable based on responder-chain action resolution.
        autoenablesItems = false

        var hasPrecedingItem = false
        var pendingSeparator = false

        for element in elements {
            switch element {
            case .separator:
                if hasPrecedingItem {
                    pendingSeparator = true
                }
            case .item(let item):
                if pendingSeparator {
                    addItem(.separator())
                    pendingSeparator = false
                }
                let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                menuItem.isEnabled = item.isEnabled
                if let systemImage = item.systemImage {
                    menuItem.image = NSImage(
                        systemSymbolName: systemImage,
                        accessibilityDescription: nil
                    )
                }
                if item.isEnabled {
                    let target = CmuxContextMenuActionTarget(handler: item.action)
                    menuItem.target = target
                    menuItem.action = #selector(CmuxContextMenuActionTarget.invoke(_:))
                    actionTargets.append(target)
                }
                addItem(menuItem)
                hasPrecedingItem = true
            }
        }
    }
}
