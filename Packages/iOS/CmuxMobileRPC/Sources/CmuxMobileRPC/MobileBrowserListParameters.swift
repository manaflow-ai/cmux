import Foundation

/// Typed parameters for `mobile.browser.list`.
struct MobileBrowserListParameters: Encodable, Sendable {
    /// The Mac-local workspace identifier.
    let workspaceID: String

    /// Creates browser-list parameters.
    init(workspaceID: String) { self.workspaceID = workspaceID }

    private enum CodingKeys: String, CodingKey { case workspaceID = "workspace_id" }
}
