import Foundation

/// Loads and saves the saved SSH hosts (``SavedHostsDocument``) in the home
/// daemon's personal frontend projection, with compare-and-swap like
/// ``WindowStateStore``. Use only on the home (local) daemon: saved hosts
/// are personal state and never go to a remote daemon.
public actor SavedHostsStore {
    public static let subject = "ssh-hosts"

    private let connection: DaemonConnection
    private var revision: UInt64 = 0
    public private(set) var document = SavedHostsDocument()
    /// Set while the last load read a document this build cannot read: every write refuses with it.
    private var unreadable: UnreadableProjection?

    public init(connection: DaemonConnection) {
        self.connection = connection
    }

    /// Fetches the stored document (empty when none or unreadable). A document this build cannot read (another
    /// schema, or one that does not decode) shows as empty and is never written over (``UnreadableProjection``).
    @discardableResult
    public func load() async throws -> SavedHostsDocument {
        let projection = try await connection.frontendProjection(subject: Self.subject)
        revision = projection.projectionRevision
        unreadable = nil
        document = SavedHostsDocument()
        guard projection.projection != .null else { return document }
        // An older schema has no migration: it reads as empty and the next write replaces it, as before.
        // Only a newer schema, or a document this build cannot decode, is kept from being written over.
        if projection.schemaVersion < SavedHostsDocument.schemaVersion { return document }
        guard projection.schemaVersion == SavedHostsDocument.schemaVersion,
              let stored = try? SavedHostsDocument(jsonValue: projection.projection) else {
            unreadable = UnreadableProjection(subject: Self.subject, schemaVersion: projection.schemaVersion,
                                              readableSchemaVersion: SavedHostsDocument.schemaVersion)
            return document
        }
        document = stored
        return document
    }

    /// Applies `change` to the latest document and writes it when it
    /// changed. A revision conflict (another window saved first) reloads and
    /// reapplies, at most three times. Throws ``UnreadableProjection`` instead of writing over a stored
    /// document this build cannot read.
    @discardableResult
    public func update(_ change: @Sendable (inout SavedHostsDocument) -> Void) async throws -> SavedHostsDocument {
        var attempts = 0
        // wakeup-allow: bounded CAS retry (3 attempts), each reloads the document from the daemon
        while true {
            var next = document
            change(&next)
            if next == document { return next }
            if let unreadable { throw unreadable }
            do {
                let stored = try await connection.putFrontendProjection(
                    subject: Self.subject, schemaVersion: SavedHostsDocument.schemaVersion,
                    projection: try next.jsonValue(), expectedRevision: revision)
                revision = stored.projectionRevision
                document = next
                return next
            } catch DaemonError.command(_, let message, _, _, _) where message.contains("revision conflict") && attempts < 3 {
                attempts += 1
                try await load()
            }
        }
    }
}
