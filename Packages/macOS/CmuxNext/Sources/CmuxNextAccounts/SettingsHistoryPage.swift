public import CmuxNextActions
public import CmuxNextDaemonService
public import CmuxNextPages
public import CmuxNextSettings
public import Foundation

/// The Settings page's Undo, Redo and Reset <card> on the daemon's durable settings history
/// (`settings-history-v1`, cmux-tui `cmux-config` history.rs; webviews/src/pages/settings/durableHistory.ts).
///
/// The page never calls the daemon's `settings.*` itself (cmux-tui page_access.rs gives a page none of
/// them). This host forwards `cmux.settings.history`, `.undo`, `.restore` and `.reset_group` to the
/// daemon's operations of the same name the way the app sends `settings.edit` (``DaemonSettingsFile``,
/// origin `app`, the person), so the page's undo takes back a user-only row as the person's own edit
/// would. `cmux.settings.reset_keys` (a card that is no one schema group) is one `settings.edit` of
/// resets through ``SettingsController/resetSettings(_:by:)``: one history entry either way. A daemon
/// without the history answers `unknown_op`, and the page keeps its own undo stack.
@MainActor
public final class SettingsHistoryPage: PageProvider {
    public static let ops = ["cmux.settings.history", "cmux.settings.undo", "cmux.settings.restore",
                             "cmux.settings.reset_group", "cmux.settings.reset_keys"]

    /// `settings.history` as JSON, nil when the daemon cannot answer (``DaemonSettingsFile/history()``).
    private let read: @MainActor () async throws -> Data?
    /// A history write as the person (``DaemonSettingsFile/historyWrite(_:params:idempotencyKey:)``).
    private let write: @MainActor (_ operation: String, _ params: Data, _ idempotencyKey: String) async throws -> Data?
    private let settings: SettingsController
    /// Who the call writes for (the Settings page is the person, ``SettingWriter/user``).
    private let writer: @MainActor (PageCallContext) -> SettingWriter
    /// The settings page's refusal of a call that may not write as the person.
    private let personOnly: PageError

    public init(read: @escaping @MainActor () async throws -> Data?,
                write: @escaping @MainActor (_ operation: String, _ params: Data, _ idempotencyKey: String) async throws -> Data?,
                settings: SettingsController,
                writer: @escaping @MainActor (PageCallContext) -> SettingWriter, personOnly: PageError) {
        self.read = read
        self.write = write
        self.settings = settings
        self.writer = writer
        self.personOnly = personOnly
    }

    /// The page part over this daemon's settings owner (the home daemon's, as the app's writes go).
    public convenience init(daemon service: DaemonService, settings: SettingsController,
                            writer: @escaping @MainActor (PageCallContext) -> SettingWriter, personOnly: PageError) {
        let daemon = service.settingsFile
        self.init(read: { try await daemon.history() },
                  write: { try await daemon.historyWrite($0, params: $1, idempotencyKey: $2) },
                  settings: settings, writer: writer, personOnly: personOnly)
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard Self.ops.contains(op) else { throw PageError.unknownOp(op) }
        if op == "cmux.settings.history" {
            guard let data = try await read() else { throw PageError.unknownOp(op) }
            // main-actor-ok: one settings history row's JSON (a few hundred bytes)
            return try JSONDecoder().decode(JSONValue.self, from: data)
        }
        let writer = self.writer(context)
        guard writer == .user else { throw personOnly }
        let key = params["idempotency_key"]?.stringValue ?? UUID().uuidString
        if op == "cmux.settings.reset_keys" {
            let descriptors = try (params["keys"]?.arrayValue ?? []).map { key in
                guard let id = key.stringValue, let descriptor = SettingsSchema.descriptor(for: CmuxConfigFile.keyPath(from: id)) else {
                    throw PageError(code: "cmux.settings.invalid", message: "\(String(describing: key)) is not a setting")
                }
                return descriptor
            }
            do {
                try await settings.resetSettings(descriptors, by: writer)
            } catch {
                throw PageError.failed(error, code: "cmux.settings.history_refused")
            }
            return reply(keys: .array(descriptors.map { .string($0.id) }), revision: .null)
        }
        var fields: [String: JSONValue] = [:]
        for field in ["revision", "group"] { if let value = params[field] { fields[field] = value } }
        let answer: Data?
        do {
            answer = try await write("settings." + op.dropFirst("cmux.settings.".count),
                                    // main-actor-ok: one settings history row's fields (a few hundred bytes)
                                    JSONEncoder().encode(JSONValue.object(fields)), key)
        } catch {
            throw PageError.failed(error, code: "cmux.settings.history_refused")
        }
        guard let answer else { throw PageError.unknownOp(op) }
        // main-actor-ok: the daemon's one-row write answer (a few hundred bytes)
        let written = try JSONDecoder().decode(JSONValue.self, from: answer)
        // The page reads the scope next; this load makes it current, as reset_all does.
        await settings.reload()
        return reply(keys: written["keys"] ?? .array([]), revision: written["history_revision"] ?? .null)
    }

    /// The page's mutation result (webviews ops.ts `HistoryMutationResult`): the host's load revision,
    /// and the daemon's revision of the recorded change, which `cmux.settings.restore` takes.
    private func reply(keys: JSONValue, revision: JSONValue) -> JSONValue {
        ["value": ["keys": keys], "revision": .string(String(settings.loadCount)), "history_revision": revision, "replayed": false]
    }
}

extension SettingsHistoryPage {
    /// The palette's Undo Settings Change (`settings.undo` in the action catalog): the settings
    /// history's undo of the newest change of any writer, as the action's origin (the person's run
    /// writes as `app`, so it takes back a user-only row; an agent's run, as itself, may not).
    public static func bindUndo(into registry: ActionRegistry, daemon service: DaemonService) {
        registry.bindEffect("settings.undo", effect: { invocation in
            let daemon = service.settingsFile
            let origin = invocation.origin == .user ? "app" : invocation.origin.rawValue
            // action-wait-allow: the settings file is the daemon's; an undo shows only once its owner wrote the earlier text back
            return .waiting(.daemonEcho) {
                do {
                    let written = try await daemon.historyWrite("settings.undo", params: Data("{}".utf8),
                                                                idempotencyKey: UUID().uuidString, origin: origin)
                    return written == nil ? ActionWorkFailure(SettingsWriterDisconnected().description) : nil
                } catch {
                    return ActionWorkFailure(String(describing: error))
                }
            }
        })
    }
}
