public import AppKit
public import CmuxNextCompat

/// Native menus follow Text Size (`appearance.metrics.chromeFontSize`; David Beyer, 2026-11-20: one text size for the
/// sidebar, menus and chat). Each menu cmux shows (a context menu, a pop-up button's or a toolbar button's, and its
/// submenus, which take their supermenu's font) draws at the system menu size times the person's text scale
/// (``Typography/userScale``), set as it begins tracking, before AppKit lays it out. The menu bar's menus stay the
/// system's. At the default size a menu is never touched, so one that sets its own font keeps it; a menu this sized
/// goes back to the system size once the scale is back at 1.
///
/// The app keeps one for its life:
///
/// ```swift
/// let menuTextSize = MenuTextSize(tracking: MenuTracking())
/// ```
@MainActor
public final class MenuTextSize {
    private let tracking: MenuTracking
    private let scale: @MainActor () -> CGFloat
    private let mainMenu: @MainActor () -> NSMenu?
    /// The menus this sized, so a return to the default size puts them back (weak: a menu is freed as usual).
    private let sized = NSHashTable<NSMenu>.weakObjects()

    /// - Parameters:
    ///   - tracking: The menus AppKit tracks (tests pass one on their own notification center).
    ///   - scale: The person's text scale; ``Typography/userScale`` by default.
    ///   - mainMenu: The menu bar, whose menus keep the system size; `NSApp.mainMenu` by default.
    public init(tracking: MenuTracking, scale: @escaping @MainActor () -> CGFloat = { Typography.userScale },
                mainMenu: @escaping @MainActor () -> NSMenu? = { NSApp?.mainMenu }) {
        self.tracking = tracking
        self.scale = scale
        self.mainMenu = mainMenu
        tracking.subscribe { [weak self] change in
            guard case let .began(menu) = change else { return }
            self?.size(menu)
        }
    }

    /// The menu font's point size at `scale` over the system's `base`: half points, as chrome text rounds.
    public static func size(base: CGFloat, scale: CGFloat) -> CGFloat {
        (base * scale * 2).rounded() / 2
    }

    private func size(_ menu: NSMenu) {
        if let main = mainMenu(), Self.root(of: menu) === main { return }
        let base = NSFont.menuFont(ofSize: 0).pointSize
        let scale = scale()
        if abs(scale - 1) < 0.001 {
            guard sized.contains(menu) else { return }
            sized.remove(menu)
            menu.font = NSFont.menuFont(ofSize: base)
            return
        }
        let points = Self.size(base: base, scale: scale)
        guard menu.font?.pointSize != points else { return }
        menu.font = NSFont.menuFont(ofSize: points)
        sized.add(menu)
    }

    private static func root(of menu: NSMenu) -> NSMenu {
        var top = menu
        while let parent = top.supermenu { top = parent }
        return top
    }
}
