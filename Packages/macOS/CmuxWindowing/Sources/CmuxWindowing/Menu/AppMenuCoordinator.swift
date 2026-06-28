public import AppKit

/// Owns the stateless application/dock menu-building decisions, lifted out of the
/// `@main` app target so menu structure stops living as inline `NSMenu` assembly
/// on the delegate. Emits Sendable value specs (``DockMenuSpec``); the live
/// `NSMenu`/`NSMenuItem` materialization, the `@objc` selector wiring, and
/// `String(localized:)` title resolution stay app-side in the witness.
///
/// Generic over the concrete host and weak-refs it (mirrors
/// ``WindowLifecycleCoordinator``) so the delegate ↔ coordinator reference is
/// one-directional in ownership: the delegate owns this coordinator strongly,
/// this coordinator weak-refs back, so there is no retain cycle. The host is not
/// read by the current stateless decision; it is held so future menu-validation
/// decisions can reach app-side leaf state through the seam.
///
/// `@MainActor` because the dock menu is built from AppKit's
/// `applicationDockMenu(_:)` callback on the main thread, so the decision lives
/// where its caller lives.
@MainActor
public final class AppMenuCoordinator<Host: AppMenuHosting> {
    /// App-side menu-validation seam, held weakly so the delegate ↔ coordinator
    /// ownership stays one-directional (the delegate owns this coordinator
    /// strongly).
    public weak var host: Host?

    public init(host: Host) {
        self.host = host
    }

    /// The dock menu shown when the user right-clicks the app's Dock icon: a
    /// single "New Window" item whose already-localized title the caller passes
    /// in via `newWindowTitle`. The witness materializes the returned spec into
    /// an `NSMenu` and wires `openNewMainWindow(_:)`.
    public func dockMenuSpec(newWindowTitle: String) -> DockMenuSpec {
        DockMenuSpec(items: [
            AppMenuItemSpec(
                title: newWindowTitle,
                keyEquivalent: "",
                modifierMask: [],
                action: .newMainWindow
            ),
        ])
    }

    /// Locates the Reload-Configuration item within the app menu's items: the
    /// first item whose identifier matches `identifier`, else the first item
    /// whose title matches `localizedTitle`, else `nil`. The witness walks the
    /// live `NSMenu`, passes each item's `(identifier?.rawValue, title)` pair in
    /// order, and maps the returned index back to the concrete `NSMenuItem`; the
    /// stable identifier and the already-localized title stay app-side.
    public func locateReloadConfigurationItem(
        in items: [(identifier: String?, title: String)],
        identifier: String,
        localizedTitle: String
    ) -> Int? {
        if let index = items.firstIndex(where: { $0.identifier == identifier }) {
            return index
        }
        return items.firstIndex(where: { $0.title == localizedTitle })
    }

    /// Resolves the key-equivalent and modifier mask to assign to the
    /// Reload-Configuration menu item from the configured shortcut: when the
    /// shortcut yields a non-nil `menuItemKeyEquivalent`, that equivalent plus
    /// `modifierMask`; otherwise the cleared `("", [])` pair. The witness reads
    /// `KeyboardShortcutSettings.menuShortcut(for: .reloadConfiguration)`
    /// app-side, passes its `menuItemKeyEquivalent`/`modifierFlags`, and applies
    /// the returned values onto the live `NSMenuItem`.
    public func reloadConfigurationKeyEquivalent(
        menuItemKeyEquivalent: String?,
        modifierMask: NSEvent.ModifierFlags
    ) -> (keyEquivalent: String, modifierMask: NSEvent.ModifierFlags) {
        if let menuItemKeyEquivalent {
            return (keyEquivalent: menuItemKeyEquivalent, modifierMask: modifierMask)
        }
        return (keyEquivalent: "", modifierMask: [])
    }
}
