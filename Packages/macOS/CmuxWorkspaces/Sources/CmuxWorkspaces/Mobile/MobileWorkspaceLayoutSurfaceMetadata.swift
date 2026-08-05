/// Mac-side metadata that maps a bonsplit tab to its mobile surface identity.
public struct MobileWorkspaceLayoutSurfaceMetadata: Equatable, Sendable {
    /// The stable panel identifier exposed to mobile clients.
    public let id: String

    /// The raw panel type exposed to mobile clients.
    public let type: String

    /// The surface's current display title.
    public let title: String

    /// Creates metadata for one bonsplit tab.
    ///
    /// - Parameters:
    ///   - id: The stable panel identifier exposed to mobile clients.
    ///   - type: The raw panel type exposed to mobile clients.
    ///   - title: The surface's current display title.
    public init(id: String, type: String, title: String) {
        self.id = id
        self.type = type
        self.title = title
    }
}
