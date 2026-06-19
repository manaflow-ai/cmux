import Foundation

/// A ``BindableCommandCatalogProviding`` that returns no commands. Used in
/// previews and tests, and as the default when no host catalog is injected.
@MainActor
public struct NoopBindableCommandCatalog: BindableCommandCatalogProviding {
    /// Creates a no-op catalog.
    public init() {}

    /// Always returns an empty list.
    public func bindableCommands() async -> [BindableCommandDescriptor] { [] }
}
