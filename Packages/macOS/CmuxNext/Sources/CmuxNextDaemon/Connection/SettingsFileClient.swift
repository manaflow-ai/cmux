import Foundation

/// cmux-next.json as the daemon's settings owner keeps it (`settings-edit-v1`, cmux-tui
/// `cmux-config`, plans/cmux-next/settings-react.md section 3): the app's writes of the file are
/// `settings.edit` operations. The owner checks each edit, edits the JSONC text in place (comments
/// and unknown keys stay), publishes it atomically and bumps the settings revision.
public struct SettingsFileClient: Sendable {
    public let connection: DaemonConnection

    public init(connection: DaemonConnection) {
        self.connection = connection
    }

    /// The settings file the owner reads and writes (`settings.snapshot` `path`): the configured
    /// path, not a symlink's target.
    public func path() async throws -> String {
        try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "settings.snapshot", params: [:], idempotencyKey: nil)
        }, as: SnapshotPath.self).path
    }

    /// Applies `edits` (`{op, path, value?}` each) in order, in one publish, as the hosting app
    /// (origin `app`, the person's own writes). Returns the indexes of the edits that applied; a
    /// conditional edit whose condition did not hold is left out.
    public func edit(_ edits: [JSONValue], idempotencyKey: String) async throws -> [Int] {
        try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "settings.edit",
                                    params: ["edits": .array(edits), "origin": .string("app")],
                                    idempotencyKey: idempotencyKey)
        }, as: ResourceMutationResult<EditChange>.self).value.applied
    }

    private struct SnapshotPath: Decodable, Sendable {
        var path: String
    }

    private struct EditChange: Decodable, Sendable {
        var applied: [Int]
    }
}
