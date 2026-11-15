import CmuxNextCompat
public import CmuxNextDaemon
public import Foundation

/// cmux-next.json as this daemon's settings owner writes it (`settings.edit`, cmux-tui
/// `cmux-config`), the file's one writer (plans/cmux-next/settings-react.md section 1). The app
/// hands ``edit(json:file:)`` to the settings module (`SettingsEditSender`), so every write of the
/// Settings page, the palette, the control socket and the launch passes comes here.
public nonisolated struct DaemonSettingsFile: Sendable {
    let daemon: @MainActor @Sendable () -> DaemonService?
    private let served = ServedFiles()

    public init(daemon: @escaping @MainActor @Sendable () -> DaemonService?) {
        self.daemon = daemon
    }

    /// Applies `json` (the `settings.edit` edits, `[{op, path, value?}]`) to the settings file at
    /// `file` in one publish. Returns the indexes of the edits that applied, or nil when this daemon
    /// cannot take the write: not live, without `settings-edit-v1`, or its owner serves another file
    /// than `file` (a daemon another build started). Nothing queues.
    public func edit(json: String, file: URL) async throws -> [Int]? {
        let connection = await MainActor.run { () -> DaemonConnection? in
            guard let daemon = daemon(), daemon.isLive, daemon.supports(DaemonCapability.settingsEdit.rawValue) else { return nil }
            return daemon.connection
        }
        guard let connection else { return nil }
        let client = SettingsFileClient(connection: connection)
        guard try await served.path(of: connection, client) == file.standardizedFileURL.path else { return nil }
        let edits = try JSONDecoder().decode([JSONValue].self, from: Data(json.utf8))
        return try await client.edit(edits, idempotencyKey: UUID().uuidString)
    }

    /// The settings file each connection's owner serves, read once per connection.
    private nonisolated final class ServedFiles: Sendable {
        private let paths = Mutex<[ObjectIdentifier: String]>([:])

        func path(of connection: DaemonConnection, _ client: SettingsFileClient) async throws -> String {
            let key = ObjectIdentifier(connection)
            if let path = paths.withLock({ $0[key] }) { return path }
            let path = URL(fileURLWithPath: try await client.path()).standardizedFileURL.path
            paths.withLock { $0[key] = path }
            return path
        }
    }
}

extension DaemonService {
    /// This daemon as the writer of cmux-next.json (the home daemon's, at launch).
    public var settingsFile: DaemonSettingsFile { DaemonSettingsFile { [weak self] in self } }
}
