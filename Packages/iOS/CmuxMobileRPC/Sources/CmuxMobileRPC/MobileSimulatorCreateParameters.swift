import Foundation

/// Typed parameters for `mobile.simulator.create`.
struct MobileSimulatorCreateParameters: Encodable, Sendable {
    let workspaceID: String

    init(workspaceID: String) { self.workspaceID = workspaceID }

    private enum CodingKeys: String, CodingKey { case workspaceID = "workspace_id" }
}
