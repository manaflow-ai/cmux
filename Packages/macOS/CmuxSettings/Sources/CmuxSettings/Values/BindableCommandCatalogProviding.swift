import Foundation

/// Host-supplied source of the commands a user may bind a custom keyboard
/// shortcut to. The Settings UI calls ``bindableCommands()`` when the user opens
/// the command picker; the host (app target) resolves the focused window's
/// command list, excludes commands that already map to a built-in action, and
/// returns the remainder.
///
/// Implementations must be `@MainActor`-safe; the UI awaits the result from a
/// view action.
@MainActor
public protocol BindableCommandCatalogProviding: Sendable {
    /// The commands available for custom binding, in display order.
    func bindableCommands() async -> [BindableCommandDescriptor]
}
