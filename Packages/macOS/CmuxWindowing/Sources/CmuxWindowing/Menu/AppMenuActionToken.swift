/// The app-target action a dock/app-menu item triggers, named as a value so the
/// menu-building decision can live in this package while the live `@objc`
/// selector plus the item's `target`/`action` wiring stays app-side.
///
/// The witness materializes a spec carrying one of these tokens into an
/// `NSMenuItem` (or an `NSMenuItem.separator()`), binding the concrete selector.
public enum AppMenuActionToken: Sendable, Hashable {
    /// Opens a new main terminal window (app-side `openNewMainWindow(_:)`).
    case newMainWindow

    /// A menu separator (`NSMenuItem.separator()`); carries no action.
    case separator
}
