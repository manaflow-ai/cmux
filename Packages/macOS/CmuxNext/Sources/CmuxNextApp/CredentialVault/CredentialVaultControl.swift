import CmuxNextControl
import CmuxNextSettings
import Foundation

/// The vault over the control socket (`cmux vault …`, cmux issue 26412). No method is in the
/// remote relay allowlist: a remote party never reads or writes this Mac's vault.
///
/// - `vault.list`: every secret's name, scope, note and use times; never a value.
/// - `vault.set {name, value, scope?, note?}` / `vault.remove {name}` / `vault.scope {name, scope}`:
///   the person only (an agent caller is refused; it asks with `vault.request`).
/// - `vault.resolve {names, command?}`: the values for a `cmux vault exec`, all or none, each
///   name allowed for the caller's scope; every grant and refusal is an audit line.
/// - `vault.request {name, reason?}`: asks the person on a native sheet to enter the value (the
///   Chief's secure entry); the answer says whether it was stored, never the value.
/// - `vault.audit {limit?}`: the newest audit lines.
enum CredentialVaultControl {
    /// A person types the value; the sheet waits for them, this only ends a lost one.
    static let requestDeadline: Duration = .seconds(600)

    /// What `vault.request` asks the person.
    struct EntryRequest: Equatable, Sendable {
        var name: String
        var reason: String?
        /// Who asks, in the person's words ("the Chief", "agent session X").
        var requester: String
        var replaces: Bool
    }

    /// The person's answer: the value and who may use it.
    struct EntryAnswer: Equatable, Sendable {
        var value: String
        var scope: [CredentialVault.Consumer]
    }

    typealias Ask = @MainActor @Sendable (EntryRequest) async -> EntryAnswer?

    static func methods(vault: @escaping @Sendable () -> CredentialVault?, ask: @escaping Ask) -> [ControlMethod] {
        [
            .async("vault.list") { _ in
                let vault = try available(vault)
                return ["secrets": .array(try run { try vault.list() }.sorted { $0.key < $1.key }.map { json(name: $0.key, $0.value) })]
            },
            .async("vault.audit") { call in
                let limit = min(max(call.params["limit"]?.intValue ?? 50, 1), CredentialVault.auditKeep)
                return ["records": .array(try run { try available(vault).audit(limit: limit) }.map(json))]
            },
            .async("vault.set") { call in
                let name = try text(call.params, "name")
                guard let value = call.params["value"]?.stringValue else { throw missingParam("vault.set", "value") }
                let scope = try scope(call.params)
                let note = try optionalText(call.params, "note")
                let replaced = try run { try available(vault).set(name, value: value, scope: scope, note: note, by: caller(call.params)) }
                return ["stored": .string(name), "replaced": .bool(replaced)]
            },
            .async("vault.scope") { call in
                let name = try text(call.params, "name")
                guard let scope = try scope(call.params) else { throw missingParam("vault.scope", "scope") }
                try run { try available(vault).setScope(name, scope: scope, by: caller(call.params)) }
                return ["name": .string(name), "scope": .array(scope.map { .string($0.rawValue) })]
            },
            .async("vault.remove") { call in
                let name = try text(call.params, "name")
                let existed = try run { try available(vault).remove(name, by: caller(call.params)) }
                return ["removed": .string(name), "existed": .bool(existed)]
            },
            .async("vault.resolve") { call in
                guard let items = call.params["names"]?.arrayValue, !items.isEmpty else { throw missingParam("vault.resolve", "names") }
                let names = try items.map { item in
                    guard let name = item.stringValue else { throw ControlError.invalidParams(CredentialVaultStrings.namesMustBeStrings) }
                    return name
                }
                let command = try optionalText(call.params, "command")
                let values = try run { try available(vault).resolve(names, for: caller(call.params), command: command) }
                return ["values": .object(values.mapValues(JSONValue.string))]
            },
            .async("vault.request") { call in
                let name = try text(call.params, "name")
                guard CredentialVault.isValidName(name) else { throw error(.invalidName(name)) }
                let reason = try optionalText(call.params, "reason").map { String($0.prefix(CredentialVault.maxNoteCharacters)) }
                let store = try available(vault)
                let asker = try caller(call.params)
                let replaces = try run { try store.list()[name] != nil }
                let request = EntryRequest(name: name, reason: reason, requester: asker.label, replaces: replaces)
                guard let answer = await askUntilClosed(request, ask: ask, connection: call.connection) else {
                    throw ControlError(code: "declined", message: CredentialVaultStrings.declined(name), data: ["name": .string(name)])
                }
                // The person typed it: the write is theirs, with the request's reason as the note.
                let person = CredentialVault.Caller(consumer: .user, label: CredentialVaultStrings.personAskedBy(asker.label))
                try run {
                    try store.set(name, value: answer.value, scope: answer.scope, note: reason.flatMap { replaces ? nil : $0 },
                                  by: person, event: "request")
                }
                return ["stored": .string(name), "replaced": .bool(replaces), "scope": .array(answer.scope.map { .string($0.rawValue) })]
            }.withDeadline(.fixed(requestDeadline)),
        ]
    }

    /// The sheet's answer, ended (nil, sheet dismissed) when the request ends first: its deadline
    /// passed or its connection closed (Ctrl-C). Nothing is stored for a request nobody waits for.
    private static func askUntilClosed(_ request: EntryRequest, ask: @escaping Ask, connection: ControlConnectionID) async -> EntryAnswer? {
        let sheet = Task { @MainActor in await ask(request) }
        let token = ControlConnectionClosures.shared.add(connection) { sheet.cancel() }
        defer { ControlConnectionClosures.shared.remove(token) }
        let answer = await withTaskCancellationHandler { await sheet.value } onCancel: { sheet.cancel() }
        return Task.isCancelled || sheet.isCancelled ? nil : answer
    }

    // MARK: Params

    /// The request's caller (`caller` as the CLI adds it): an agent session or a Chief turn is an
    /// agent; a terminal or no caller is the person.
    static func caller(_ params: [String: JSONValue]) throws -> CredentialVault.Caller {
        guard let raw = params["caller"], !raw.isNull else { return .init(consumer: .user, label: CredentialVaultStrings.you) }
        guard let members = raw.objectValue else { throw ControlError.invalidParams(CredentialVaultStrings.callerMustBeObject) }
        if let session = members["agent_session"]?.stringValue, !session.isEmpty {
            return .init(consumer: .agents, label: members["home_chat"]?.boolValue == true
                ? CredentialVaultStrings.chief : CredentialVaultStrings.agentSession(String(session.prefix(64))))
        }
        if members["home_chat"]?.boolValue == true { return .init(consumer: .agents, label: CredentialVaultStrings.chief) }
        if let terminal = members["terminal_id"]?.stringValue, !terminal.isEmpty {
            return .init(consumer: .user, label: CredentialVaultStrings.terminal(String(terminal.prefix(64))))
        }
        return .init(consumer: .user, label: CredentialVaultStrings.you)
    }

    /// `scope`: an array of `user` and `agents`, or one comma-separated string; nil when absent.
    static func scope(_ params: [String: JSONValue]) throws -> [CredentialVault.Consumer]? {
        guard let raw = params["scope"], !raw.isNull else { return nil }
        let words: [String]
        if let text = raw.stringValue {
            words = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        } else if let items = raw.arrayValue {
            words = items.compactMap(\.stringValue)
            guard words.count == items.count else { throw ControlError.invalidParams(CredentialVaultStrings.badScope) }
        } else {
            throw ControlError.invalidParams(CredentialVaultStrings.badScope)
        }
        let scope = try words.map { word in
            guard let consumer = CredentialVault.Consumer(rawValue: word) else { throw ControlError.invalidParams(CredentialVaultStrings.badScope) }
            return consumer
        }
        guard !scope.isEmpty else { throw error(.emptyScope) }
        return scope
    }

    private static func text(_ params: [String: JSONValue], _ key: String) throws -> String {
        guard let value = params[key]?.stringValue, !value.isEmpty else { throw missingParam("vault", key) }
        return value
    }

    private static func optionalText(_ params: [String: JSONValue], _ key: String) throws -> String? {
        guard let raw = params[key], !raw.isNull else { return nil }
        guard let value = raw.stringValue else { throw ControlError.invalidParams(CredentialVaultStrings.mustBeString(key)) }
        return value
    }

    private static func missingParam(_ method: String, _ key: String) -> ControlError {
        ControlError.invalidParams(CredentialVaultStrings.missingParam(method, key))
    }

    private static func available(_ vault: () -> CredentialVault?) throws -> CredentialVault {
        guard let vault = vault() else { throw ControlError(code: "unavailable", message: CredentialVaultStrings.unavailable) }
        return vault
    }

    /// `body` with a vault failure as its control error.
    private static func run<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let failure as CredentialVault.Failure {
            throw error(failure)
        }
    }

    static func error(_ failure: CredentialVault.Failure) -> ControlError {
        switch failure {
        case .invalidName(let name):
            ControlError.invalidParams(CredentialVaultStrings.invalidName(name), data: ["name": .string(name)])
        case .invalidValue(let name):
            ControlError.invalidParams(CredentialVaultStrings.invalidValue(name), data: ["name": .string(name)])
        case .invalidNote:
            ControlError.invalidParams(CredentialVaultStrings.invalidNote)
        case .emptyScope:
            ControlError.invalidParams(CredentialVaultStrings.badScope)
        case .missing(let names):
            ControlError(code: "vault.missing", message: CredentialVaultStrings.missing(names), data: ["names": .array(names.map(JSONValue.string))])
        case .denied(let names, let consumer):
            ControlError(code: "vault.denied", message: CredentialVaultStrings.denied(names, consumer: consumer),
                         data: ["names": .array(names.map(JSONValue.string)), "consumer": .string(consumer.rawValue)])
        case .agentsMayNotWrite:
            ControlError(code: "vault.user_only", message: CredentialVaultStrings.agentsMayNotWrite)
        case .keychain(let status):
            ControlError(code: "vault.keychain", message: CredentialVaultStrings.keychain(status), data: ["status": JSONValue(Int(status))])
        case .index(let path):
            ControlError(code: "vault.index", message: CredentialVaultStrings.index(path))
        }
    }

    // MARK: JSON

    static func json(name: String, _ entry: CredentialVault.Entry) -> JSONValue {
        [
            "name": .string(name),
            "scope": .array(entry.scope.map { .string($0.rawValue) }),
            "note": entry.note.map(JSONValue.string) ?? .null,
            "created_ms": .number(Double(entry.createdMs)),
            "updated_ms": .number(Double(entry.updatedMs)),
            "last_used_ms": entry.lastUsedMs.map { .number(Double($0)) } ?? .null,
            "last_used_by": entry.lastUsedBy.map(JSONValue.string) ?? .null,
            "uses": JSONValue(entry.uses),
        ]
    }

    static func json(_ record: CredentialVault.AuditRecord) -> JSONValue {
        [
            "at_ms": .number(Double(record.atMs)),
            "event": .string(record.event),
            "names": .array(record.names.map(JSONValue.string)),
            "by": .string(record.by),
            "consumer": .string(record.consumer.rawValue),
            "command": record.command.map(JSONValue.string) ?? .null,
            "outcome": .string(record.outcome),
        ]
    }
}
