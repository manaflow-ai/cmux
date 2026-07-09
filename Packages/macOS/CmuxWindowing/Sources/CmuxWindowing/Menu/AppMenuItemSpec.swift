public import AppKit

/// A single materializable dock/app-menu item: the witness builds an
/// `NSMenuItem` from this value, sets the key equivalent (and its modifier mask
/// when the equivalent is non-empty), and wires the live selector for `action`.
///
/// `title` is the already-resolved display string; localization
/// (`String(localized:)`) stays app-side, so the package never touches a string
/// catalog.
public struct AppMenuItemSpec: Sendable, Equatable {
    /// The resolved item title (empty for a separator).
    public var title: String

    /// The key-equivalent character (empty when the item has no shortcut).
    public var keyEquivalent: String

    /// The modifier mask applied to the key equivalent. Only materialized onto
    /// the `NSMenuItem` when `keyEquivalent` is non-empty.
    public var modifierMask: NSEvent.ModifierFlags

    /// The action the materialized item triggers.
    public var action: AppMenuActionToken

    public init(
        title: String,
        keyEquivalent: String,
        modifierMask: NSEvent.ModifierFlags,
        action: AppMenuActionToken
    ) {
        self.title = title
        self.keyEquivalent = keyEquivalent
        self.modifierMask = modifierMask
        self.action = action
    }
}
