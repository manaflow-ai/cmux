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

/// The owner's settings history (`settings-history-v1`, cmux-tui `cmux-config` history.rs): every
/// published change of the file, and the writes that go back through it. The Settings page reaches
/// these only through the app (page_access.rs gives a page no `settings.*` operation), which
/// writes as origin `app`, the person, as ``SettingsFileClient/edit(_:file:idempotencyKey:)`` does.
extension SettingsFileClient {
    /// The capability the history operations need.
    public static let historyCapability = "settings-history-v1"

    /// The operations the app forwards for the Settings page.
    public enum HistoryWrite: String, Sendable, CaseIterable {
        case undo = "settings.undo"
        case restore = "settings.restore"
        case resetGroup = "settings.reset_group"
    }

    /// `settings.history`: `{entries}`, newest first.
    public func history() async throws -> JSONValue {
        try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "settings.history", params: [:])
        }, as: JSONValue.self, requiring: Self.historyCapability)
    }

    /// One history write as `origin` (`app`, the person, by default): its keys and the revision of the change it
    /// recorded (what `settings.restore` takes).
    public func historyWrite(_ write: HistoryWrite, params: [String: JSONValue],
                             idempotencyKey: String, origin: String = "app") async throws -> (keys: [String], revision: String?) {
        var fields = params
        fields["origin"] = .string(origin)
        let sent = fields
        let result = try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: write.rawValue, params: sent, idempotencyKey: idempotencyKey)
        }, as: ResourceMutationResult<HistoryChange>.self, requiring: Self.historyCapability)
        return (result.value.keys, result.revision)
    }

    private struct HistoryChange: Decodable, Sendable {
        var keys: [String]
    }
}
