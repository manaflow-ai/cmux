import Foundation

/// Typed parameters for `mobile.browser.create`.
struct MobileBrowserCreateParameters: Encodable, Sendable {
    /// The Mac-local workspace identifier.
    let workspaceID: String

    /// Creates browser-create parameters.
    init(workspaceID: String) { self.workspaceID = workspaceID }

    private enum CodingKeys: String, CodingKey { case workspaceID = "workspace_id" }
}
