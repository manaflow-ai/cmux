import Foundation

/// Retains a menu item's action closure and exposes it to the Objective-C
/// target/action mechanism. `NSMenuItem.target` is a *weak* reference, so the
/// owning ``CmuxContextMenu`` keeps these targets alive for the menu's lifetime.
///
/// Internal implementation detail of ``CmuxContextMenu``; exposed to the test
/// target through `@testable import`.
@MainActor
final class CmuxContextMenuActionTarget: NSObject {
    private let handler: @MainActor () -> Void

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init()
    }

    @objc func invoke(_ sender: Any?) {
        handler()
    }
}
