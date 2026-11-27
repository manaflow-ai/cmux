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

    public init(connection: DaemonConnection) {
        self.connection = connection
    }

    /// Fetches the stored document (empty when none or schema unknown).
    @discardableResult
    public func load() async throws -> SavedHostsDocument {
        let projection = try await connection.frontendProjection(subject: Self.subject)
        revision = projection.projectionRevision
        if projection.schemaVersion == SavedHostsDocument.schemaVersion, projection.projection != .null {
            document = (try? SavedHostsDocument(jsonValue: projection.projection)) ?? SavedHostsDocument()
        } else {
            document = SavedHostsDocument()
        }
        return document
    }

    /// Applies `change` to the latest document and writes it when it
    /// changed. A revision conflict (another window saved first) reloads and
    /// reapplies, at most three times.
    @discardableResult
    public func update(_ change: @Sendable (inout SavedHostsDocument) -> Void) async throws -> SavedHostsDocument {
        var attempts = 0
        // wakeup-allow: bounded CAS retry (3 attempts), each reloads the document from the daemon
        while true {
            var next = document
            change(&next)
            if next == document { return next }
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
