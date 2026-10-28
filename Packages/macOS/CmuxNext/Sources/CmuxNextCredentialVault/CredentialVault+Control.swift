public import AppKit
public import CmuxNextControl
public import CmuxNextSettings
import CmuxNextCompat
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
nonisolated extension CredentialVault {
    /// A person types the value; the sheet waits for them, this only ends a lost one.
    static let requestDeadline: Duration = .seconds(600)

    /// What `vault.request` asks the person.
    public struct EntryRequest: Equatable, Sendable {
        public var name: String
        public var reason: String?
        /// Who asks, in the person's words ("the Chief", "agent session X"); empty when the person
        /// asked themselves (Settings), so the sheet names no asker.
        public var requester: String
        public var replaces: Bool
        /// A key the person pasted in a message (the Home composer): the sheet shows it filled in
        /// and lets them rename it. Empty for a request from an agent.
        public var pasted: String
        /// Who may use it now (a replaced secret's scope): the sheet's Agents box starts from it,
        /// and the answer keeps its other consumers.
        public var scope: [Consumer]
        /// The value the person typed on a sheet that comes back (the name they chose was taken):
        /// filled in again, with their name in the name field.
        public var typed: String = ""
        /// The sheet came back because the name the person chose is taken.
        public var taken = false

        public init(name: String, reason: String?, requester: String, replaces: Bool, pasted: String = "",
                    scope: [Consumer] = Consumer.allCases) {
            self.name = name
            self.reason = reason
            self.requester = requester
            self.replaces = replaces
            self.pasted = pasted
            self.scope = scope
        }
    }

    /// The person's answer: the value and who may use it.
    public struct EntryAnswer: Equatable, Sendable {
        /// The name it goes under (the request's, or the person's for a pasted key).
        public var name: String
        public var value: String
        public var scope: [Consumer]

        public init(name: String, value: String, scope: [Consumer]) {
            self.name = name
            self.value = value
            self.scope = scope
        }
    }

    /// What became of a pasted key the person was offered to move.
    public enum PasteMove: Equatable, Sendable {
        case moved(String)
        /// The person cancelled the sheet: they keep it in the message.
        case cancelled
        /// The vault could not store it (the Keychain or the index refused).
        case failed
    }

    /// Moves a key the person pasted in a message to the vault on its sheet in `window`. A name
    /// the vault holds is never replaced from here: the sheet comes back saying so.
    @MainActor
    public func movePasted(_ value: String, suggestedName: String, in window: NSWindow) async -> PasteMove {
        let person = Caller(consumer: .user, label: CredentialVaultStrings.homeChat)
        do {
            let name = try await enterNew(Self.pasteRequest(suggestedName: suggestedName, value: value), by: person, event: "paste") {
                await Self.askForEntry($0, in: window)
            }
            return name.map(PasteMove.moved) ?? .cancelled
        } catch {
            return .failed
        }
    }

    /// Asks with `ask` until the person saves under a name the vault does not hold yet, and stores
    /// it there; the name, nil when they cancelled. A taken name brings the sheet back with their
    /// name and value and a line saying it is taken: nothing they typed is lost, nothing is replaced.
    @MainActor
    func enterNew(_ request: EntryRequest, by person: Caller, event: String, note: String? = nil,
                  ask: (EntryRequest) async -> EntryAnswer?) async throws -> String? {
        var request = request
        while let answer = await ask(request) {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try self.set(answer.name, value: answer.value, scope: answer.scope, note: note, by: person, event: event, onlyNew: true)
                }.value
                return answer.name
            } catch Failure.exists(let name) {
                request.name = name
                request.typed = answer.value
                request.scope = answer.scope
                request.reason = nil
                request.taken = true
            }
        }
        return nil
    }

    /// Shows the secure entry sheet and answers what the person saved (nil: cancelled or closed).
    public typealias Ask = @MainActor @Sendable (EntryRequest) async -> EntryAnswer?

    /// The `vault.*` methods over this vault, with `ask` as the person's entry sheet and `approve`
    /// as their approval of what only they may do (``Approval``).
    public func controlMethods(ask: @escaping Ask, approve: @escaping Approve) -> [ControlMethod] {
        VaultControl.methods(vault: self, ask: ask, approve: approve)
    }
}

/// The method bodies and their params (internal: the public surface is ``CredentialVault/controlMethods(ask:approve:)``).
nonisolated enum VaultControl {
    typealias EntryRequest = CredentialVault.EntryRequest
    typealias EntryAnswer = CredentialVault.EntryAnswer
    typealias Ask = CredentialVault.Ask
    typealias Approve = CredentialVault.Approve

    static func methods(vault: CredentialVault, ask: @escaping Ask, approve: @escaping Approve,
                        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) -> [ControlMethod] {
        /// Who calls, as its params claim; a claim to be the person counts only once the person
        /// allowed the call on their sheet (``ApprovalGate``).
        let caller: @Sendable (ControlCall) throws -> CredentialVault.Caller = { call in try Self.caller(call.params) }
        let gate = ApprovalGate(approve: approve, now: now)
        let deadline = ControlMethod.Deadline.fixed(CredentialVault.requestDeadline)
        return [
            .async("vault.list") { _ in
                return ["secrets": .array(try run { try vault.list() }.sorted { $0.key < $1.key }.map { json(name: $0.key, $0.value) })]
            },
            .async("vault.audit") { call in
                let limit = min(max(call.params["limit"]?.intValue ?? 50, 1), CredentialVault.auditKeep)
                return ["records": .array(try run { try vault.audit(limit: limit) }.map(json))]
            },
            .async("vault.set") { call in
                let name = try text(call.params, "name")
                guard let value = call.params["value"]?.stringValue else { throw missingParam("vault.set", "value") }
                let scope = try scope(call.params)
                let note = try optionalText(call.params, "note")
                let by = try caller(call)
                // The sheet says Save or Replace; the write holds to what it said (Save never replaces).
                var onlyNew = false
                if by.consumer == .user, CredentialVault.isValidName(name), call.connection != .inProcess {
                    let replaces = try run { try vault.list()[name] != nil }
                    try await gate.allowed(.store(name: name, replaces: replaces, scope: scope), call, vault: vault, by: by, event: "set")
                    onlyNew = !replaces
                }
                let replaced = try run { try vault.set(name, value: value, scope: scope, note: note, by: by, onlyNew: onlyNew) }
                return ["stored": .string(name), "replaced": .bool(replaced)]
            }.withDeadline(deadline),
            .async("vault.scope") { call in
                let name = try text(call.params, "name")
                guard let scope = try scope(call.params) else { throw missingParam("vault.scope", "scope") }
                let by = try caller(call)
                if by.consumer == .user, call.connection != .inProcess {
                    try await gate.allowed(.scope(name: name, scope: scope), call, vault: vault, by: by, event: "scope")
                }
                try run { try vault.setScope(name, scope: scope, by: by) }
                return ["name": .string(name), "scope": .array(scope.map { .string($0.rawValue) })]
            }.withDeadline(deadline),
            .async("vault.remove") { call in
                let name = try text(call.params, "name")
                let by = try caller(call)
                if by.consumer == .user, call.connection != .inProcess {
                    try await gate.allowed(.remove(name: name), call, vault: vault, by: by, event: "remove")
                }
                let existed = try run { try vault.remove(name, by: by) }
                return ["removed": .string(name), "existed": .bool(existed)]
            }.withDeadline(deadline),
            .async("vault.resolve") { call in
                guard let items = call.params["names"]?.arrayValue, !items.isEmpty else { throw missingParam("vault.resolve", "names") }
                let names = try items.map { item in
                    guard let name = item.stringValue else { throw ControlError.invalidParams(CredentialVaultStrings.namesMustBeStrings) }
                    return name
                }
                let command = try optionalText(call.params, "command")
                let by = try caller(call)
                // Which secrets need the person is decided under the vault's lock, with the read
                // (resolve's `approved`): the person approves exactly those, then it reads again.
                var approved: Set<String>? = call.connection == .inProcess ? nil : []
                for _ in 0..<3 {
                    do {
                        let values = try vault.resolve(names, for: by, command: command, approved: approved)
                        return ["values": .object(values.mapValues(JSONValue.string))]
                    } catch CredentialVault.Failure.needsApproval(let kept) {
                        let program = command.flatMap(CredentialVault.displayProgram)
                        try await gate.allowed(.use(names: kept, program: program), call, vault: vault, by: by, event: "use", command: command)
                        approved?.formUnion(kept)
                    } catch let failure as CredentialVault.Failure {
                        throw error(failure)
                    }
                }
                throw ControlError(code: "vault.not_approved", message: CredentialVaultStrings.declinedApproval(names.joined(separator: ", ")))
            }.withDeadline(deadline),
            .async("vault.request") { call in
                let name = try text(call.params, "name")
                guard CredentialVault.isValidName(name) else { throw error(.invalidName(name)) }
                let reason = try optionalText(call.params, "reason").map { String($0.prefix(CredentialVault.maxNoteCharacters)) }
                let store = vault
                let asker = try caller(call)
                let existing = try run { try store.list()[name] }
                let replaces = existing != nil
                // A socket asker is always named: one that did not say it is an agent reads as "a cmux
                // command", never as the person's own request. Only an agent's asks start agent-usable.
                let label = asker.consumer == .agents ? asker.label : CredentialVaultStrings.cmuxCommand
                let request = EntryRequest(name: name, reason: reason, requester: label, replaces: replaces,
                                           scope: existing?.scope ?? (asker.consumer == .agents ? CredentialVault.Consumer.allCases : [.user]))
                // The person typed it: the write is theirs, with the request's reason as the note.
                let person = CredentialVault.Caller(consumer: .user, label: CredentialVaultStrings.personAskedBy(label))
                let connection = call.connection
                let declined = ControlError(code: "declined", message: CredentialVaultStrings.declined(name), data: ["name": .string(name)])
                guard replaces else {
                    // A new name: a secret made under it while the sheet was open is never replaced;
                    // the sheet comes back with what the person typed (``CredentialVault/enterNew``).
                    let stored: String?
                    do {
                        stored = try await store.enterNew(request, by: person, event: "request", note: reason) { @MainActor request in
                            await Self.askUntilClosed(request, ask: ask, connection: connection)
                        }
                    } catch let failure as CredentialVault.Failure {
                        throw error(failure)
                    }
                    guard let stored else { throw declined }
                    let scope = try run { try store.list()[stored]?.scope } ?? []
                    return ["stored": .string(stored), "replaced": false, "scope": .array(scope.map { .string($0.rawValue) })]
                }
                guard let answer = await askUntilClosed(request, ask: ask, connection: connection) else { throw declined }
                try run { try store.set(name, value: answer.value, scope: answer.scope, note: nil, by: person, event: "request") }
                return ["stored": .string(name), "replaced": true, "scope": .array(answer.scope.map { .string($0.rawValue) })]
            }.withDeadline(deadline),
        ]
    }

    /// The person's approvals for one set of methods: one sheet open at a time, and after the
    /// person declines (or does not answer) an approval, the same ask is refused without a sheet
    /// for ``backoff``, so a caller cannot keep a sheet in front of them until a click lands. The
    /// app's in-process calls never get here.
    final class ApprovalGate: Sendable {
        static let backoff: Duration = .seconds(30)
        private struct State {
            var open = false
            var refusedUntil: [String: ContinuousClock.Instant] = [:]
        }
        private let state = Mutex(State())
        private let approve: Approve
        private let now: @Sendable () -> ContinuousClock.Instant

        init(approve: @escaping Approve, now: @escaping @Sendable () -> ContinuousClock.Instant) {
            self.approve = approve
            self.now = now
        }

        /// Returns when the person allowed `approval`; otherwise throws `vault.not_approved` (and
        /// audits it): they declined or closed it, the request ended first (its deadline, Ctrl-C),
        /// another approval is open, or they declined the same ask within ``backoff``.
        func allowed(_ approval: CredentialVault.Approval, _ call: ControlCall, vault: CredentialVault, by: CredentialVault.Caller,
                     event: String, command: String? = nil) async throws {
            let key = Self.key(approval)
            let names = Self.names(approval)
            let refusal = { (message: String) -> ControlError in
                vault.auditRefusal(event: event, names: names, by: by, command: command)
                return ControlError(code: "vault.not_approved", message: message, data: ["names": .array(names.map(JSONValue.string))])
            }
            let at = now()
            let start: String? = state.withLock { state in
                if state.open { return CredentialVaultStrings.approvalOpen }
                if let until = state.refusedUntil[key], at < until { return CredentialVaultStrings.declinedApproval(names.joined(separator: ", ")) }
                state.open = true
                return nil
            }
            if let start { throw refusal(start) }
            let sheet = Task { @MainActor [approve] in await approve(approval) }
            let token = ControlConnectionClosures.shared.add(call.connection) { sheet.cancel() }
            let yes = await withTaskCancellationHandler { await sheet.value } onCancel: { sheet.cancel() }
            ControlConnectionClosures.shared.remove(token)
            let allowed = yes && !Task.isCancelled && !sheet.isCancelled
            let ended = now()
            state.withLock { state in
                state.open = false
                state.refusedUntil = state.refusedUntil.filter { $0.value > ended }
                if !allowed { state.refusedUntil[key] = ended.advanced(by: Self.backoff) }
            }
            guard allowed else { throw refusal(CredentialVaultStrings.declinedApproval(names.joined(separator: ", "))) }
        }

        static func names(_ approval: CredentialVault.Approval) -> [String] {
            switch approval {
            case .use(let names, _): names
            case .store(let name, _, _), .remove(let name), .scope(let name, _): [name]
            }
        }

        private static func key(_ approval: CredentialVault.Approval) -> String {
            switch approval {
            case .use(let names, _): "use:" + names.sorted().joined(separator: ",")
            case .store(let name, _, _): "set:" + name
            case .remove(let name): "remove:" + name
            case .scope(let name, _): "scope:" + name
            }
        }
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

    /// The caller its params claim (`caller`, as the CLI adds it): an agent session or a Chief turn
    /// is an agent; a terminal or no caller claims to be the person. A claim can only narrow:
    /// anything the person alone may do over the socket waits for their approval sheet.
    static func caller(_ params: [String: JSONValue]) throws -> CredentialVault.Caller {
        guard let raw = params["caller"], !raw.isNull else { return .init(consumer: .user, label: CredentialVaultStrings.you) }
        guard let members = raw.objectValue else { throw ControlError.invalidParams(CredentialVaultStrings.callerMustBeObject) }
        if let session = members["agent_session"]?.stringValue, !session.isEmpty {
            return .init(consumer: .agents, label: members["home_chat"]?.boolValue == true
                ? CredentialVaultStrings.chief : CredentialVaultStrings.agentSession(identifier(session)))
        }
        if members["home_chat"]?.boolValue == true { return .init(consumer: .agents, label: CredentialVaultStrings.chief) }
        if let terminal = members["terminal_id"]?.stringValue, !terminal.isEmpty {
            return .init(consumer: .user, label: CredentialVaultStrings.terminal(identifier(terminal)))
        }
        return .init(consumer: .user, label: CredentialVaultStrings.you)
    }

    /// A caller-chosen id as the sheet and the audit show it: letters, digits, `-`, `_`, `.` and
    /// `:` only, at most 40, so it cannot carry words of its own.
    static func identifier(_ raw: String) -> String {
        let kept = raw.unicodeScalars.filter { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "-_.:".unicodeScalars.contains($0) }
        let text = String(String.UnicodeScalarView(kept.prefix(40)))
        return text.isEmpty ? "?" : text
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
        case .exists(let name):
            ControlError(code: "vault.exists", message: CredentialVaultStrings.alreadyThere(name), data: ["name": .string(name)])
        case .needsApproval(let names):
            ControlError(code: "vault.not_approved", message: CredentialVaultStrings.declinedApproval(names.joined(separator: ", ")),
                         data: ["names": .array(names.map(JSONValue.string))])
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
