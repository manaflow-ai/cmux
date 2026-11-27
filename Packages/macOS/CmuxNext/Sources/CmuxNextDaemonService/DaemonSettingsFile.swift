public import CmuxNextDaemon
public import Foundation

/// cmux-next.json as this daemon's settings owner writes it (`settings.edit`, cmux-tui
/// `cmux-config`), the file's one writer (plans/cmux-next/settings-react.md section 1). The app
/// hands ``edit(json:file:)`` to the settings module (`SettingsEditSender`), so every write of the
/// Settings page, the palette, the control socket and the launch passes comes here.
public nonisolated struct DaemonSettingsFile: Sendable {
    /// The daemon's connection while it can take a settings write (``DaemonService/settingsWriteConnection``).
    let connection: @MainActor @Sendable () -> DaemonConnection?

    public init(connection: @escaping @MainActor @Sendable () -> DaemonConnection?) {
        self.connection = connection
    }

    /// Applies `json` (the `settings.edit` edits, `[{op, path, value?}]`) to the settings file at
    /// `file` in one publish. Returns the indexes of the edits that applied, or nil when this daemon
    /// cannot take the write: not live, without `settings-edit-v2`, the connection lost during the
    /// request, or its owner serves another file than `file` (a daemon another build started, or
    /// one restarted on another `CMUX_NEXT_CONFIG_FILE`). Each edit names `file`, so the owner
    /// checks it on the write itself (`settings.file_mismatch`). Nothing queues.
    public func edit(json: String, file: URL) async throws -> [Int]? {
        guard let connection = await self.connection() else { return nil }
        let edits = try JSONDecoder().decode([JSONValue].self, from: Data(json.utf8))
        do {
            return try await SettingsFileClient(connection: connection)
                .edit(edits, file: file.standardizedFileURL.path, idempotencyKey: UUID().uuidString)
        } catch let error as DaemonError where Self.cannotWrite(error) {
            return nil
        }
    }

    /// `settings.history` as JSON (`{entries}`, newest first), or nil when this daemon cannot answer:
    /// not live, or without `settings-history-v1` (an older daemon; the page keeps its own undo).
    public func history() async throws -> Data? {
        guard let connection = await self.connection() else { return nil }
        do {
            return try JSONEncoder().encode(try await SettingsFileClient(connection: connection).history())
        } catch let error as DaemonError where Self.cannotWrite(error) || Self.missingHistory(error) {
            return nil
        }
    }

    /// `settings.undo`, `settings.restore` or `settings.reset_group` (`operation`) with `params` (a JSON
    /// object: `revision`, `group`), as `origin` (`app`, the person, unless an action run names another).
    /// Answers JSON `{keys, history_revision}`,
    /// or nil when this daemon cannot take it (as ``history()``).
    public func historyWrite(_ operation: String, params: Data, idempotencyKey: String, origin: String = "app") async throws -> Data? {
        guard let write = SettingsFileClient.HistoryWrite(rawValue: operation),
              let connection = await self.connection() else { return nil }
        let fields = try JSONDecoder().decode([String: JSONValue].self, from: params)
        do {
            let reply = try await SettingsFileClient(connection: connection)
                .historyWrite(write, params: fields, idempotencyKey: idempotencyKey, origin: origin)
            let answer: JSONValue = .object(["keys": .array(reply.keys.map(JSONValue.string)),
                                             "history_revision": reply.revision.map(JSONValue.string) ?? .null])
            return try JSONEncoder().encode(answer)
        } catch let error as DaemonError where Self.cannotWrite(error) || Self.missingHistory(error) {
            return nil
        }
    }

    static func missingHistory(_ error: DaemonError) -> Bool {
        if case .missingCapabilities = error { return true }
        return false
    }

    /// The owner serves another file, or the connection went away before the reply (not a missed
    /// deadline: that edit may still apply).
    static func cannotWrite(_ error: DaemonError) -> Bool {
        switch error {
        case .notConnected, .connectionClosed, .daemonShutdown, .connectFailed: true
        case .command(_, _, let code, _, _): code == SettingsFileClient.fileMismatch
        default: false
        }
    }
}

extension DaemonService {
    /// This daemon as the writer of cmux-next.json (the home daemon's, at launch).
    public var settingsFile: DaemonSettingsFile { DaemonSettingsFile { [weak self] in self?.settingsWriteConnection } }

    /// The connection while this daemon is live and serves `settings-edit-v2`, else nil.
    var settingsWriteConnection: DaemonConnection? {
        isLive && supports(DaemonCapability.settingsEdit.rawValue) ? connection : nil
    }
}
