/// App-bundle localized socket error strings for custom-sidebar commands.
public struct ControlCustomSidebarCommandMessages: Sendable, Equatable {
    /// Error used when validate/reload receives an explicitly empty name.
    public let invalidName: String

    /// Error used when select receives a missing or empty name.
    public let selectMissingName: String

    /// Creates the command message set.
    ///
    /// - Parameters:
    ///   - invalidName: Error used when validate/reload receives an explicitly empty name.
    ///   - selectMissingName: Error used when select receives a missing or empty name.
    public init(invalidName: String, selectMissingName: String) {
        self.invalidName = invalidName
        self.selectMissingName = selectMissingName
    }
}
