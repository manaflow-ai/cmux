/// One coding-agent model returned to the mobile task composer.
public struct MobileTaskModel: Equatable, Sendable {
    /// CLI identifier passed to the provider.
    public let id: String
    /// Product name displayed verbatim by the composer.
    public let displayName: String

    /// Creates a discovered task model.
    ///
    /// - Parameters:
    ///   - id: CLI identifier passed to the provider.
    ///   - displayName: Product name displayed by the composer.
    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}
