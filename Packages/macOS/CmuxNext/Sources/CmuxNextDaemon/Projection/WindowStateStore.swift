import Foundation

/// Loads and saves the window-state document with compare-and-swap.
public actor WindowStateStore {
    public static let defaultSubject = "windows"

    private let connection: DaemonConnection
    private let subject: String
    private var revision: UInt64 = 0
    public private(set) var document = WindowStateDocument()
    /// Set while the last load read a document this build cannot read: every write refuses with it.
    private var unreadable: UnreadableProjection?

    /// `subject` scopes the document; use one per profile/device when several
    /// Macs share a daemon.
    public init(connection: DaemonConnection, subject: String = WindowStateStore.defaultSubject) {
        self.connection = connection
        self.subject = subject
    }

    /// Fetches the stored document (empty when none or unreadable). A document this build cannot read (another
    /// schema, or one that does not decode) shows as empty and is never written over (``UnreadableProjection``).
    @discardableResult
    public func load() async throws -> WindowStateDocument {
        let projection = try await connection.frontendProjection(subject: subject)
        revision = projection.projectionRevision
        unreadable = nil
        document = WindowStateDocument()
        guard projection.projection != .null else { return document }
        // An older schema has no migration: it reads as empty and the next write replaces it, as before.
        // Only a newer schema, or a document this build cannot decode, is kept from being written over.
        if projection.schemaVersion < WindowStateDocument.schemaVersion { return document }
        guard projection.schemaVersion == WindowStateDocument.schemaVersion,
              let stored = try? WindowStateDocument(jsonValue: projection.projection) else {
            unreadable = UnreadableProjection(subject: subject, schemaVersion: projection.schemaVersion,
                                              readableSchemaVersion: WindowStateDocument.schemaVersion)
            return document
        }
        document = stored
        return document
    }

    /// Applies `change` to the latest document and writes it. On a CAS
    /// conflict (another window or device saved first) it reloads, reapplies
    /// the change, and retries, so per-window upserts from several windows
    /// never overwrite each other. Throws ``UnreadableProjection`` instead of writing over a stored document
    /// this build cannot read.
    @discardableResult
    public func update(_ change: @Sendable (inout WindowStateDocument) -> Void) async throws -> WindowStateDocument {
        var attempts = 0
        // wakeup-allow: bounded CAS retry (3 attempts), each reloads the document from the daemon
        while true {
            var next = document
            change(&next)
            // Nothing to store: no durable write (a no-op focus or selection
            // action answers without a daemon round trip).
            if next == document { return next }
            if let unreadable { throw unreadable }
            do {
                let stored = try await connection.putFrontendProjection(
                    subject: subject, schemaVersion: WindowStateDocument.schemaVersion,
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

    public func save(window: WindowRecord) async throws {
        try await update { $0.upsert(window) }
    }

    public func removeWindow(id: String) async throws {
        try await update { $0.removeWindow(id: id) }
    }
}
