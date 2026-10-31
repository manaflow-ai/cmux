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
        /// A socket call opened it, not the person's own action: it does not take the keyboard
        /// when it appears, and only a click saves (``CredentialVault/entrySheet(_:)``).
        public var unprompted = false

        public init(name: String, reason: String?, requester: String, replaces: Bool, pasted: String = "",
                    scope: [Consumer] = Consumer.allCases, unprompted: Bool = false) {
            self.name = name
            self.reason = reason
            self.requester = requester
            self.replaces = replaces
            self.pasted = pasted
            self.scope = scope
            self.unprompted = unprompted
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
    public func controlMethods(ask: @escaping Ask, approve: @escaping Approve,
                               enabled: @escaping @Sendable () -> Bool = { CredentialVault.isRolloutEnabled }) -> [ControlMethod] {
        VaultControl.methods(vault: self, ask: ask, approve: approve, enabled: enabled)
    }
}

/// The method bodies and their params (internal: the public surface is ``CredentialVault/controlMethods(ask:approve:enabled:)``).
nonisolated enum VaultControl {
    typealias EntryRequest = CredentialVault.EntryRequest
    typealias EntryAnswer = CredentialVault.EntryAnswer
    typealias Ask = CredentialVault.Ask
    typealias Approve = CredentialVault.Approve

    static func methods(vault: CredentialVault, ask: @escaping Ask, approve: @escaping Approve,
                        enabled: @escaping @Sendable () -> Bool = { true },
                        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) -> [ControlMethod] {
        /// Who calls, as its params claim; a claim to be the person counts only once the person
        /// allowed the call on their sheet (``ApprovalGate``).
        let caller: @Sendable (ControlCall) throws -> CredentialVault.Caller = { call in try Self.caller(call.params) }
        let gate = ApprovalGate(approve: approve, now: now)
        let deadline = ControlMethod.Deadline.fixed(CredentialVault.requestDeadline)
        func guarded(_ name: String, _ body: @escaping @Sendable (ControlCall) async throws -> JSONValue) -> ControlMethod {
            .async(name) { call in
                guard enabled() else { throw ControlError(code: "vault.disabled", message: CredentialVaultStrings.disabled) }
                return try await body(call)
            }
        }
        return [
            guarded("vault.list") { _ in
                return ["secrets": .array(try run { try vault.list() }.sorted { $0.key < $1.key }.map { json(name: $0.key, $0.value) })]
            },
            guarded("vault.audit") { call in
                let limit = min(max(call.params["limit"]?.intValue ?? 50, 1), CredentialVault.auditKeep)
                return ["records": .array(try run { try vault.audit(limit: limit) }.map(json))]
            },
            guarded("vault.set") { call in
                let name = try text(call.params, "name")
                guard let value = call.params["value"]?.stringValue else { throw missingParam("vault.set", "value") }
                let scope = try scope(call.params)
                let note = try optionalText(call.params, "note")
                let by = try caller(call)
                // The sheet says Save or Replace and the scope; the write holds to what it said (Save never replaces).
                var onlyNew = false
                var stored = scope
                if by.consumer == .user, CredentialVault.isValidName(name), call.connection != .inProcess {
                    let index = try run { try vault.list() }
                    let existing = index[name]
                    // A name the vault would refuse (another spelling of one it holds) asks nothing.
                    if existing == nil, let clash = index.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                        throw error(.exists(clash))
                    }
                    let effective = scope ?? existing?.scope ?? CredentialVault.Consumer.allCases
                    try await gate.allowed(.store(name: name, replaces: existing != nil, scope: effective), call, vault: vault, by: by, event: "set")
                    onlyNew = existing == nil
                    stored = effective
                }
                let replaced = try run { try vault.set(name, value: value, scope: stored, note: note, by: by, onlyNew: onlyNew) }
                return ["stored": .string(name), "replaced": .bool(replaced)]
            }.withDeadline(deadline),
            guarded("vault.scope") { call in
                let name = try text(call.params, "name")
                guard let scope = try scope(call.params) else { throw missingParam("vault.scope", "scope") }
                let by = try caller(call)
                if by.consumer == .user, call.connection != .inProcess {
                    guard try run({ try vault.list()[name] }) != nil else { throw error(.missing([name])) }
                    try await gate.allowed(.scope(name: name, scope: scope), call, vault: vault, by: by, event: "scope")
                }
                try run { try vault.setScope(name, scope: scope, by: by) }
                return ["name": .string(name), "scope": .array(scope.map { .string($0.rawValue) })]
            }.withDeadline(deadline),
            guarded("vault.remove") { call in
                let name = try text(call.params, "name")
                let by = try caller(call)
                if by.consumer == .user, call.connection != .inProcess {
                    guard try run({ try vault.list()[name] }) != nil else { return ["removed": .string(name), "existed": false] }
                    try await gate.allowed(.remove(name: name), call, vault: vault, by: by, event: "remove")
                }
                let existed = try run { try vault.remove(name, by: by) }
                return ["removed": .string(name), "existed": .bool(existed)]
            }.withDeadline(deadline),
            guarded("vault.resolve") { call in
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
                // Reads 0...2 may each ask; the read after the third approval is the last.
                for sheets in 0...3 {
                    do {
                        let values = try vault.resolve(names, for: by, command: command, approved: approved)
                        return ["values": .object(values.mapValues(JSONValue.string))]
                    } catch CredentialVault.Failure.needsApproval(let kept) {
                        guard sheets < 3 else {
                            vault.auditRefusal(event: "use", names: kept, by: by, command: command)
                            throw error(.needsApproval(kept))
                        }
                        let program = command.flatMap(CredentialVault.displayProgram)
                        try await gate.allowed(.use(names: kept, program: program), call, vault: vault, by: by, event: "use", command: command)
                        approved?.formUnion(kept)
                    } catch let failure as CredentialVault.Failure {
                        throw error(failure)
                    }
                }
                throw error(.needsApproval(names))
            }.withDeadline(deadline),
            guarded("vault.request") { call in
                let name = try text(call.params, "name")
                guard CredentialVault.isValidName(name) else { throw error(.invalidName(name)) }
                let reason = try optionalText(call.params, "reason").flatMap(CredentialVault.oneLine)
                let store = vault
                let asker = try caller(call)
                let existing = try run { try store.list()[name] }
                let replaces = existing != nil
                // A socket asker is always named: one that did not say it is an agent reads as "a cmux
                // command", never as the person's own request. Only an agent's asks start agent-usable.
                let label = asker.consumer == .agents ? asker.label : CredentialVaultStrings.cmuxCommand
                let request = EntryRequest(name: name, reason: reason, requester: label, replaces: replaces,
                                           scope: existing?.scope ?? (asker.consumer == .agents ? CredentialVault.Consumer.allCases : [.user]),
                                           unprompted: true)
                // The person typed it: the write is theirs, with the request's reason as the note.
                let person = CredentialVault.Caller(consumer: .user, label: CredentialVaultStrings.personAskedBy(label))
                let declined = ControlError(code: "declined", message: CredentialVaultStrings.declined(name), data: ["name": .string(name)])
                // One sheet at a time with the approvals, and a request the person cancelled is not
                // asked again for a while (``ApprovalGate``).
                let answer: String??
                do {
                    answer = try await gate.sheet(key: "request:" + name, names: [name], call, vault: vault, by: asker,
                                                  event: "request") { @MainActor () async throws -> String? in
                        guard replaces else {
                            // A new name: a secret made under it while the sheet was open is never
                            // replaced; the sheet comes back with what the person typed (``CredentialVault/enterNew``).
                            return try await store.enterNew(request, by: person, event: "request", note: reason) { await ask($0) }
                        }
                        guard let answer = await ask(request) else { return nil }
                        try await Task.detached(priority: .userInitiated) {
                            try store.set(name, value: answer.value, scope: answer.scope, note: nil, by: person, event: "request")
                        }.value
                        return name
                    } declined: { $0 == nil }
                } catch let failure as CredentialVault.Failure {
                    throw error(failure)
                }
                guard let stored = answer.flatMap({ $0 }) else { throw declined }
                let scope = try run { try store.list()[stored]?.scope } ?? []
                return ["stored": .string(stored), "replaced": .bool(replaces && stored == name),
                        "scope": .array(scope.map { .string($0.rawValue) })]
            }.withDeadline(deadline),
        ]
    }

    /// The person's sheets for one set of methods (approvals and `vault.request`): one open at a
    /// time. After the person declines one, the same ask is refused without a sheet for
    /// ``backoff`` and any ask for ``cooldown``, so a caller cannot keep sheets in front of them
    /// until a click lands. A sheet the request ended first (its deadline, Ctrl-C) holds any ask for
    /// ``cooldown`` as well, so dropping a request and asking again brings no fresh sheet at once.
    /// The app's in-process approvals never get here.
    final class ApprovalGate: Sendable {
        static let backoff: Duration = .seconds(30)
        static let cooldown: Duration = .seconds(10)
        private struct State {
            var open = false
            var refusedUntil: [String: ContinuousClock.Instant] = [:]
            var quietUntil: ContinuousClock.Instant?
        }
        private let state = Mutex(State())
        private let approve: Approve
        private let now: @Sendable () -> ContinuousClock.Instant

        init(approve: @escaping Approve, now: @escaping @Sendable () -> ContinuousClock.Instant) {
            self.approve = approve
            self.now = now
        }

        /// Returns when the person allowed `approval`; otherwise throws `vault.not_approved` (and
        /// audits it): they declined or closed it, the request ended first, or ``sheet(key:names:_:vault:by:event:command:show:declined:)`` refused to show it.
        func allowed(_ approval: CredentialVault.Approval, _ call: ControlCall, vault: CredentialVault, by: CredentialVault.Caller,
                     event: String, command: String? = nil) async throws {
            let names = Self.names(approval)
            let yes = try await sheet(key: Self.key(approval), names: names, call, vault: vault, by: by, event: event, command: command) { [approve] in
                await approve(approval)
            } declined: { !$0 }
            guard yes == true else {
                vault.auditRefusal(event: event, names: names, by: by, command: command)
                throw Self.refusal(CredentialVaultStrings.declinedApproval(names.joined(separator: ", ")), names: names)
            }
        }

        /// Shows one sheet with `show` and answers its result; nil when the request ended first
        /// (the sheet goes). Throws `vault.not_approved` (audited) without showing it when another
        /// sheet is open, the person declined `key` within ``backoff``, or any ask within ``cooldown``.
        /// `declined` says whether a result is the person's no.
        func sheet<T: Sendable>(key: String, names: [String], _ call: ControlCall, vault: CredentialVault, by: CredentialVault.Caller,
                                event: String, command: String? = nil, show: @escaping @MainActor @Sendable () async throws -> T,
                                declined: (T) -> Bool) async throws -> T? {
            let at = now()
            let busy: String? = state.withLock { state in
                if state.open { return CredentialVaultStrings.approvalOpen }
                if let until = state.quietUntil, at < until { return CredentialVaultStrings.approvalCooldown }
                if let until = state.refusedUntil[key], at < until { return CredentialVaultStrings.declinedApproval(names.joined(separator: ", ")) }
                state.open = true
                return nil
            }
            if let busy {
                vault.auditRefusal(event: event, names: names, by: by, command: command)
                throw Self.refusal(busy, names: names)
            }
            let task = Task { @MainActor in try await show() }
            // Its connection may have closed already: then the sheet ends at once.
            let token = ControlConnectionClosures.shared.add(call.connection) { task.cancel() }
            let result = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
            ControlConnectionClosures.shared.remove(token)
            let ended = Task.isCancelled || task.isCancelled
            let value = try? result.get()
            let no = !ended && value.map(declined) ?? false
            let done = now()
            state.withLock { state in
                state.open = false
                state.refusedUntil = state.refusedUntil.filter { $0.value > done }
                if no { state.refusedUntil[key] = done.advanced(by: Self.backoff) }
                if no || ended { state.quietUntil = done.advanced(by: Self.cooldown) }
            }
            if ended { return nil }
            return try result.get()
        }

        static func refusal(_ message: String, names: [String]) -> ControlError {
            ControlError(code: "vault.not_approved", message: message, data: ["names": .array(names.map(JSONValue.string))])
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
