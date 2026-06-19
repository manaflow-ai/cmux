import Foundation

/// A Command-Palette command that the user may bind a custom keyboard shortcut
/// to: its stable ``id`` and a display ``title``. Supplied to the Settings UI by
/// a ``BindableCommandCatalogProviding`` so the picker can list commands without
/// the UI package depending on the app target's command registry.
public struct BindableCommandDescriptor: Sendable, Equatable, Identifiable, Hashable {
    /// The command's stable identifier (for example `palette.triggerFlash`).
    public let id: String

    /// The command's user-facing title, evaluated for the current context.
    public let title: String

    /// Creates a descriptor.
    ///
    /// - Parameters:
    ///   - id: The command's stable identifier.
    ///   - title: The command's display title.
    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}
