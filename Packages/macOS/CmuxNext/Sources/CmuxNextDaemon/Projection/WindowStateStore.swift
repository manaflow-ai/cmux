import Foundation

/// Loads and saves the window-state document with compare-and-swap.
public actor WindowStateStore {
    public static let defaultSubject = "windows"

    private let connection: DaemonConnection
    private let subject: String
    private var revision: UInt64 = 0
    public private(set) var document = WindowStateDocument()

    /// `subject` scopes the document; use one per profile/device when several
    /// Macs share a daemon.
    public init(connection: DaemonConnection, subject: String = WindowStateStore.defaultSubject) {
        self.connection = connection
        self.subject = subject
    }

    /// Fetches the stored document (empty when none or schema unknown).
    @discardableResult
    public func load() async throws -> WindowStateDocument {
        let projection = try await connection.frontendProjection(subject: subject)
        revision = projection.projectionRevision
        if projection.schemaVersion == WindowStateDocument.schemaVersion, projection.projection != .null {
            document = (try? WindowStateDocument(jsonValue: projection.projection)) ?? WindowStateDocument()
        } else {
            document = WindowStateDocument()
        }
        return document
    }

    /// Applies `change` to the latest document and writes it. On a CAS
    /// conflict (another window or device saved first) it reloads, reapplies
    /// the change, and retries, so per-window upserts from several windows
    /// never overwrite each other.
    @discardableResult
    public func update(_ change: @Sendable (inout WindowStateDocument) -> Void) async throws -> WindowStateDocument {
        var attempts = 0
        // wakeup-allow: bounded CAS retry (3 attempts), each reloads the document from the daemon
        while true {
            var next = document
            change(&next)
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
