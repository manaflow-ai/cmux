/// One active browser stream selection retained across connection recovery.
public struct BrowserStreamSelection: Equatable, Sendable {
    /// The Mac-local workspace identifier.
    public let workspaceID: String
    /// The Mac browser panel identifier.
    public let panelID: String

    /// Creates an active browser selection.
    /// - Parameters:
    ///   - workspaceID: The Mac-local workspace identifier.
    ///   - panelID: The Mac browser panel identifier.
    public init(workspaceID: String, panelID: String) {
        self.workspaceID = workspaceID
        self.panelID = panelID
    }
}
