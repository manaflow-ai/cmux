/// A stable, sanitized load failure suitable for user-visible presentation.
public struct BrowserWebExtensionPresentationFailure: Identifiable, Equatable, Sendable {
    /// A stable identifier that does not expose a full filesystem path.
    public let id: String

    /// The managed directory entry name.
    public let entryName: String

    /// A localized generic failure message supplied by the executable.
    public let message: String

    /// Creates a sanitized presentation failure.
    ///
    /// - Parameters:
    ///   - id: A stable failure identifier.
    ///   - entryName: The managed directory entry name.
    ///   - message: A localized generic failure message.
    public init(id: String, entryName: String, message: String) {
        self.id = id
        self.entryName = entryName
        self.message = message
    }
}
