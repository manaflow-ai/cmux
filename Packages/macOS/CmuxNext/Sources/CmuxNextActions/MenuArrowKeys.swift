#if DEBUG
public import AppKit

/// The arrow keys a person presses to reach a row of an open menu (`debug.object_menu`'s `folders` and `choose`).
public enum MenuArrowKeys {
    /// The key codes that open `folders` in turn from `top`: Down (125) to each folder's row, then Right (124).
    /// Arrow keys move over enabled, shown rows (an alternate row shares its primary's place; a section header,
    /// such as cmux > Customizations' Experiments and Labs titles, is never highlighted). Nothing is highlighted
    /// in a menu that just opened, so the first Down lands on its first row; a submenu opened with Right starts on
    /// its first row. `choose`, when set, then gets Down to its row of the last menu reached and Return (36).
    /// Nil when a folder or the chosen row is not an enabled row there.
    public static func codes(_ folders: [String], choose: String? = nil, in top: NSMenu) -> [UInt16]? {
        var menu = top
        var codes: [UInt16] = []
        let rows = { (menu: NSMenu) in
            menu.items.filter { !$0.isSeparatorItem && !$0.isSectionHeader && !$0.isHidden && !$0.isAlternate && $0.isEnabled }
        }
        for (depth, title) in folders.enumerated() {
            guard let index = rows(menu).firstIndex(where: { $0.title == title }), let submenu = rows(menu)[index].submenu else { return nil }
            codes += Array(repeating: 125, count: depth == 0 ? index + 1 : index) + [124]
            menu = submenu
        }
        if let choose {
            guard let index = rows(menu).firstIndex(where: { $0.title == choose && $0.submenu == nil }) else { return nil }
            codes += Array(repeating: 125, count: folders.isEmpty ? index + 1 : index) + [36]
        }
        return codes
    }
}

/// Pops a menu up from the main run loop (`perform(_:with:afterDelay:inModes:)`), not from a main-queue block: the
/// menu's tracking runs until it closes, and inside a main-queue block it would hold the main queue, so the next
/// debug call (`folders`, `dismiss`) would wait for the menu to close. The run loop keeps it until the perform
/// fires, once; nothing else holds it.
@MainActor
public final class DelayedPopUp: NSObject {
    private let menu: NSMenu
    private let at: NSPoint
    private weak var view: NSView?

    public init(menu: NSMenu, at: NSPoint, in view: NSView) {
        self.menu = menu
        self.at = at
        self.view = view
    }

    public func schedule() {
        perform(#selector(popUp), with: nil, afterDelay: 0, inModes: [.default])
    }

    @objc private func popUp() {
        guard let view, view.window != nil else { return }
        _ = menu.popUp(positioning: nil, at: at, in: view)
    }
}
#endif
