import Foundation

/// Non-sensitive PRDashboard settings consumed by ``GHPRMetadataService``.
public struct GHPRConfiguration: Equatable, Sendable {
    public let enabled: Bool
    public let socketPath: String
    public let displayItems: [GHPRDisplayItem]
    public let jiraBaseURL: String?

    public init(
        enabled: Bool,
        socketPath: String,
        displayItems: [GHPRDisplayItem],
        jiraBaseURL: String?
    ) {
        self.enabled = enabled
        self.socketPath = socketPath
        self.displayItems = displayItems
        self.jiraBaseURL = jiraBaseURL
    }
}
