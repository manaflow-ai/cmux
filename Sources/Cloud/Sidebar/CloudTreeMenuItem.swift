import AppKit

/// Menu item carrying its own closure; the outline's context menu is rebuilt
/// per click from the clicked node, so items never outlive their target.
final class CloudTreeMenuItem: NSMenuItem {
    private let runAction: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        runAction = action
        // The selector is deliberately NOT named `perform(_:)`: that compiles
        // to `perform:`, which collides with NSObject's perform machinery and
        // the click never reached the method. `execute` mirrors the sidebar's
        // SidebarRowMenuActionItem, the proven shape.
        super.init(title: title, action: #selector(execute), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc @MainActor private func execute() {
        #if DEBUG
        cmuxDebugLog("cloudTree.menu.execute title=\(title)")
        #endif
        runAction()
    }
}

