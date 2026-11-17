import Foundation

/// cmux-next.json as the daemon's settings owner keeps it (`settings-edit-v2`, cmux-tui
/// `cmux-config`, plans/cmux-next/settings-react.md section 3): the app's writes of the file are
/// `settings.edit` operations. The owner checks each edit, edits the JSONC text in place (comments
/// and unknown keys stay), publishes it atomically and bumps the settings revision.
public struct SettingsFileClient: Sendable {
    public let connection: DaemonConnection

    /// The refusal of an edit whose `file` is not the owner's settings file; nothing was written.
    public static let fileMismatch = "settings.file_mismatch"

    public init(connection: DaemonConnection) {
        self.connection = connection
    }

    /// Applies `edits` (`{op, path, value?}` each) in order, in one publish, as the hosting app
    /// (origin `app`, the person's own writes), to `file` only: an owner serving another file
    /// refuses with ``fileMismatch``. Returns the indexes of the edits that applied; a
    /// conditional edit whose condition did not hold is left out.
    public func edit(_ edits: [JSONValue], file: String, idempotencyKey: String) async throws -> [Int] {
        try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "settings.edit",
                                    params: ["edits": .array(edits), "file": .string(file), "origin": .string("app")],
                                    idempotencyKey: idempotencyKey)
        }, as: ResourceMutationResult<EditChange>.self).value.appliedIndexes
    }

    private struct EditChange: Decodable, Sendable {
        // Not `applied`: the crash ratchet reads a name the module declares as both an array
        // and a dictionary as an array, and DaemonStore's `applied` is a dictionary.
        var appliedIndexes: [Int]

        private enum CodingKeys: String, CodingKey {
            case appliedIndexes = "applied"
        }
    }
}
