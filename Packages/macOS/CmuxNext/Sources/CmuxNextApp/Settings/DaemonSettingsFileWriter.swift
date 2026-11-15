import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextSettings
import Foundation

/// The app's writer of cmux-next.json: the home daemon's settings owner (`settings.edit`,
/// cmux-tui `cmux-config`), the file's one writer (plans/cmux-next/settings-react.md section 1).
/// Every write of the Settings page, the palette, the control socket and the launch migrations
/// goes there through ``CmuxConfigFile``. While the home daemon is not connected, does not serve
/// `settings-edit-v1`, or serves another settings file than the app reads, a write is refused
/// (``SettingsWriterDisconnected``) and nothing queues.
nonisolated struct DaemonSettingsFileWriter: SettingsFileWriter {
    /// The home daemon.
    let daemon: @MainActor @Sendable () -> DaemonService?
    private let served = ServedFiles()

    init(daemon: @escaping @MainActor @Sendable () -> DaemonService?) {
        self.daemon = daemon
    }

    func edit(_ edits: [SettingsFileEdit], file: URL) async throws -> [Int] {
        let connection = await MainActor.run { () -> DaemonConnection? in
            guard let daemon = daemon(), daemon.isLive, daemon.supports(DaemonCapability.settingsEdit.rawValue) else { return nil }
            return daemon.connection
        }
        guard let connection else { throw SettingsWriterDisconnected() }
        let client = SettingsFileClient(connection: connection)
        // The owner's file is the launch input the app gave its daemon (`CMUX_NEXT_CONFIG_FILE`); a
        // daemon that serves another file (one another build started) must not take this one's writes.
        guard try await served.path(of: connection, client) == file.standardizedFileURL.path else {
            throw SettingsWriterDisconnected()
        }
        // The settings module's JSON as the daemon client's (two JSONValue types, one JSON text).
        let text = CmuxNextSettings.JSONValue.array(edits.map(\.wire)).compactText
        let items = try JSONDecoder().decode([CmuxNextDaemon.JSONValue].self, from: Data(text.utf8))
        return try await client.edit(items, idempotencyKey: UUID().uuidString)
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
