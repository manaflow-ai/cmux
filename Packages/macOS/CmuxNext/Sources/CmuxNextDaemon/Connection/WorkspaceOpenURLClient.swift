import Foundation

/// `workspace.open_url` (`workspace-open-url-v1`, cmux-tui spec resource-api-v2.md): a web link
/// opens on the right side of a workspace, the home workspace when none is named. The daemon owns
/// the rule (reuse a browser tab on the right, never the agent chat dock, keyboard focus stays);
/// the caller only names the URL.
public struct WorkspaceOpenURLClient: Sendable {
    public let connection: DaemonConnection

    public init(_ connection: DaemonConnection) {
        self.connection = connection
    }

    /// Opens `url` (http or https) on the right side of the current session's home workspace.
    public func openOnHome(_ url: String) async throws {
        let key = "cmux-next-open-url-" + UUID().uuidString.lowercased()
        _ = try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "workspace.open_url",
                                    params: ["machine": .string("current"), "session": .string("current"), "url": .string(url)],
                                    idempotencyKey: key)
        }, as: ResourceMutationResult<JSONValue>.self)
    }
}
