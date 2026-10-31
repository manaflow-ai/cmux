import CmuxNextCompat
public import Foundation

/// The Chief vault (cmux issue 26412): credentials the person hands cmux (API keys, tokens) that
/// agents use by name without seeing them. One owner: this store. A value lives only in the login
/// Keychain (``CredentialVaultSecretStoring``), together with its authoritative scope; the folder
/// holds names, cached scopes and use times (`vault.json`) and the audit log (`vault-audit.jsonl`),
/// never a value. Agents can edit that folder, so its scope is never trusted.
///
/// Every call blocks on the Keychain or the disk: callers run them off the main actor
/// (`CredentialVaultControl` runs them on the async lane).
public nonisolated final class CredentialVault: Sendable {
    /// Who may resolve a secret: the person, and agents (agent sessions and Chief turns). A socket
    /// caller names itself (`caller`, as for `action.run`), which only narrows: a socket cannot
    /// tell the person's `cmux` from an agent's, so a use of a secret kept for the person and every
    /// write wait for the person's approval sheet (``Approval``). The boundary against other
    /// programs is the Keychain item, which only this app reads.
    public enum Consumer: String, CaseIterable, Codable, Sendable {
        case user
        case agents
    }

    /// One secret's record (no value).
    public struct Entry: Codable, Equatable, Sendable {
        public var scope: [Consumer]
        public var note: String?
        public var createdMs: Int64
        public var updatedMs: Int64
        public var lastUsedMs: Int64?
        public var lastUsedBy: String?
        public var uses: Int

        enum CodingKeys: String, CodingKey {
            case scope, note, uses
            case createdMs = "created_ms", updatedMs = "updated_ms", lastUsedMs = "last_used_ms", lastUsedBy = "last_used_by"
        }
    }

    /// Who asks, from the request's `caller` (see ``Consumer``).
    struct Caller: Equatable, Sendable {
        var consumer: Consumer
        /// "agent session X", "Chief", "terminal X", "you": the audit log's words, no secret.
        var label: String
    }

    /// One audit line: what was asked, by whom, and the outcome. Never a value.
    struct AuditRecord: Codable, Equatable, Sendable {
        var atMs: Int64
        var event: String
        var names: [String]
        var by: String
        var consumer: Consumer
        var command: String?
        var outcome: String

        enum CodingKeys: String, CodingKey {
            case event, names, by, consumer, command, outcome
            case atMs = "at_ms"
        }
    }

    enum Failure: Error, Equatable, Sendable {
        case invalidName(String)
        case invalidValue(String)
        case invalidNote
        case emptyScope
        case missing([String])
        case denied([String], Consumer)
        case agentsMayNotWrite
        /// A new secret's name is taken, or another differs from it only in case
        /// (``set(_:value:scope:note:by:event:onlyNew:)``).
        case exists(String)
        /// ``resolve(_:for:command:approved:)``: these secrets are kept for the person and were not
        /// approved for this use; nothing was released.
        case needsApproval([String])
        case keychain(Int32)
        case index(String)
    }

    /// `[A-Za-z_][A-Za-z0-9_]*`, at most 128: a name is also the default env variable it fills.
    static func isValidName(_ name: String) -> Bool {
        guard (1...128).contains(name.utf8.count), let first = name.unicodeScalars.first else { return false }
        let letter: (Unicode.Scalar) -> Bool = { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || $0 == "_" }
        return letter(first) && name.unicodeScalars.allSatisfy { letter($0) || ("0"..."9").contains($0) }
    }

    static let maxValueBytes = 64 * 1024
    static let maxNoteCharacters = 200
    /// The audit log keeps at least this many of its newest lines; it is cut back when twice as long.
    static let auditKeep = 1000

    private let secrets: any CredentialVaultSecretStoring
    private let folder: URL
    private let now: @Sendable () -> Date
    /// Serializes every read-modify-write of the index and the audit log.
    private let lock = Mutex(())
    /// Called after every change to the index (a write or a use), off the lock, on the caller's thread.
    private let observers = Mutex<[@Sendable () -> Void]>([])

    init(secrets: any CredentialVaultSecretStoring, folder: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.secrets = secrets
        self.folder = folder
        self.now = now
    }

    /// The app's vault: `<Application Support>/<bundle id>/CredentialVault`, Keychain service `<bundle id>.credential-vault`
    /// (a tagged build has its own, as its accounts keys do).
    public static func forApplication(bundleID: String?) -> CredentialVault {
        let bundle = bundleID.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        return CredentialVault(secrets: KeychainCredentialVaultSecrets(service: "\(bundle).credential-vault"),
                               folder: support.appending(path: bundle).appending(path: "CredentialVault", directoryHint: .isDirectory))
    }

    /// Runs `observer` after each change to the vault's names, scopes or use times (Settings'
    /// card reloads from it); never with a value.
    public func onChange(_ observer: @escaping @Sendable () -> Void) {
        observers.withLock { $0.append(observer) }
    }

    private func changed() {
        for observer in observers.withLock({ $0 }) { observer() }
    }

    var indexURL: URL { folder.appending(path: "vault.json") }
    var auditURL: URL { folder.appending(path: "vault-audit.jsonl") }

    // MARK: Reads

    /// Every secret's record by name.
    public func list() throws -> [String: Entry] {
        try lock.withLock { _ in try readIndex() }
    }

    /// The newest `limit` audit lines, oldest first.
    func audit(limit: Int) throws -> [AuditRecord] {
        try lock.withLock { _ in
            guard let data = try? Data(blockingContentsOf: auditURL) else { return [] }
            let lines = data.split(separator: UInt8(ascii: "\n")).suffix(max(0, limit))
            return lines.compactMap { try? JSONDecoder().decode(AuditRecord.self, from: Data($0)) }
        }
    }

    // MARK: Writes (the person only)

    /// Stores `value` under `name` (replacing one there, unless `onlyNew`); true when it replaced
    /// one. `scope` nil keeps a replaced secret's scope (new: every consumer); `note` nil keeps its
    /// note. When the index cannot be written the Keychain goes back to what it held.
    @discardableResult
    func set(_ name: String, value: String, scope: [Consumer]?, note: String?, by caller: Caller, event: String = "set",
             onlyNew: Bool = false) throws -> Bool {
        guard caller.consumer == .user else { throw Failure.agentsMayNotWrite }
        guard Self.isValidName(name) else { throw Failure.invalidName(name) }
        guard !value.isEmpty, value.utf8.count <= Self.maxValueBytes, !value.contains("\0") else { throw Failure.invalidValue(name) }
        if let note, note.count > Self.maxNoteCharacters { throw Failure.invalidNote }
        if let scope, scope.isEmpty { throw Failure.emptyScope }
        defer { changed() }
        return try lock.withLock { _ in
            var index = try readIndex()
            let at = millis()
            let old = index[name]
            if onlyNew, old != nil { throw Failure.exists(name) }
            // The Keychain may match account names without regard to case: one name per spelling.
            if old == nil, let clash = index.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                throw Failure.exists(clash)
            }
            // Read even when the cache omits this name: a deleted cache must not orphan or
            // broaden a protected item, and rollback must preserve its value and scope together.
            let previous = try secrets.record(for: name)
            if onlyNew, previous != nil { throw Failure.exists(name) }
            let effective = Self.ordered(scope ?? previous?.scope ?? Consumer.allCases)
            try secrets.save(CredentialVaultSecretRecord(value: value, scope: effective), for: name)
            index[name] = Entry(scope: effective,
                                note: (note ?? old?.note).flatMap { $0.isEmpty ? nil : $0 },
                                createdMs: old?.createdMs ?? at, updatedMs: at, lastUsedMs: old?.lastUsedMs,
                                lastUsedBy: old?.lastUsedBy, uses: old?.uses ?? 0)
            do {
                try writeIndex(index)
            } catch {
                if let previous { try? secrets.save(previous, for: name) } else { try? secrets.delete(name) }
                throw error
            }
            appendAudit(AuditRecord(atMs: at, event: event, names: [name], by: caller.label, consumer: caller.consumer,
                                    command: nil, outcome: old == nil ? "stored" : "replaced"))
            return old != nil
        }
    }

    /// Changes who may use `name`. A caller whose gesture may be synthetic passes
    /// `agentsApproved: false`: widening the current protected scope then throws `needsApproval`
    /// before any write. A stale Settings snapshot cannot bypass the person's approval.
    func setScope(_ name: String, scope: [Consumer], by caller: Caller, agentsApproved: Bool = true) throws {
        guard caller.consumer == .user else { throw Failure.agentsMayNotWrite }
        guard !scope.isEmpty else { throw Failure.emptyScope }
        defer { changed() }
        try lock.withLock { _ in
            var index = try readIndex()
            guard var entry = index[name] else { throw Failure.missing([name]) }
            guard let previous = try secrets.record(for: name) else { throw Failure.missing([name]) }
            if !agentsApproved, scope.contains(.agents), !previous.scope.contains(.agents) {
                throw Failure.needsApproval([name])
            }
            entry.scope = Self.ordered(scope)
            entry.updatedMs = millis()
            index[name] = entry
            try secrets.save(CredentialVaultSecretRecord(value: previous.value, scope: entry.scope), for: name)
            do {
                try writeIndex(index)
            } catch {
                try? secrets.save(previous, for: name)
                throw error
            }
            appendAudit(AuditRecord(atMs: entry.updatedMs, event: "scope", names: [name], by: caller.label, consumer: caller.consumer,
                                    command: nil, outcome: entry.scope.map(\.rawValue).joined(separator: ",")))
        }
    }

    /// Removes `name` from the index, then the Keychain (the index goes back when the Keychain
    /// refuses, so a listed name always has its value); false when there was none (nothing changes).
    @discardableResult
    func remove(_ name: String, by caller: Caller) throws -> Bool {
        guard caller.consumer == .user else { throw Failure.agentsMayNotWrite }
        defer { changed() }
        return try lock.withLock { _ in
            let before = try readIndex()
            var index = before
            // A name the index does not hold is never deleted from the Keychain: it may match
            // another name's item there without regard to case.
            guard index.removeValue(forKey: name) != nil else {
                appendAudit(AuditRecord(atMs: millis(), event: "remove", names: [name], by: caller.label, consumer: caller.consumer,
                                        command: nil, outcome: "absent"))
                return false
            }
            try writeIndex(index)
            do {
                try secrets.delete(name)
            } catch {
                try? writeIndex(before)
                throw error
            }
            appendAudit(AuditRecord(atMs: millis(), event: "remove", names: [name], by: caller.label, consumer: caller.consumer,
                                    command: nil, outcome: "removed"))
            return true
        }
    }

    // MARK: Use

    /// The values of `names` for `caller`, all or none: every name must exist and allow the
    /// caller's consumer. Each grant or refusal is one audit line naming `command`. With
    /// `approved`, a secret kept for the person (no `agents` in its scope) is released only when
    /// it is in that set; others throw ``Failure/needsApproval(_:)``, decided under the same lock
    /// as the release (a secret stored between an approval check and the read cannot slip out).
    /// nil: the app's own call, no approval.
    func resolve(_ names: [String], for caller: Caller, command: String?, approved: Set<String>? = nil) throws -> [String: String] {
        var seen = Set<String>()
        let names = names.filter { seen.insert($0).inserted }
        if let bad = names.first(where: { !Self.isValidName($0) }) { throw Failure.invalidName(bad) }
        defer { changed() }
        return try lock.withLock { _ in
            var index = try readIndex()
            let at = millis()
            let record = { (outcome: String) in
                self.appendAudit(AuditRecord(atMs: at, event: "use", names: names, by: caller.label, consumer: caller.consumer,
                                             command: command.map(Self.commandSummary), outcome: outcome))
            }
            let missing = names.filter { index[$0] == nil }
            guard missing.isEmpty else {
                record("missing")
                throw Failure.missing(missing)
            }
            let denied = names.filter { !(index[$0]?.scope.contains(caller.consumer) ?? false) }
            guard denied.isEmpty else {
                record("denied")
                throw Failure.denied(denied, caller.consumer)
            }
            if let approved {
                let kept = names.filter { index[$0].map { !$0.scope.contains(.agents) } == true && !approved.contains($0) }
                guard kept.isEmpty else { throw Failure.needsApproval(kept) }
            }
            var values: [String: String] = [:]
            for name in names {
                guard let secret = try secrets.record(for: name), var entry = index[name] else {
                    record("missing")
                    throw Failure.missing([name])
                }
                values[name] = secret.value
                entry.lastUsedMs = at
                entry.lastUsedBy = caller.label
                // The display cache is writable by same-UID processes: normalize negative
                // counts and saturate so malformed metadata cannot trap an allowed read.
                entry.uses = min(max(0, entry.uses), Int.max - 1) + 1
                index[name] = entry
            }
            try writeIndex(index)
            record("granted")
            return values
        }
    }

    // MARK: Files

    private func millis() -> Int64 { Int64((now().timeIntervalSince1970 * 1000).rounded()) }

    private static func ordered(_ scope: [Consumer]) -> [Consumer] {
        Consumer.allCases.filter(scope.contains)
    }

    /// A refusal that happened before the vault was touched (the person did not approve it): one
    /// audit line, so a declined or unanswered approval shows in `cmux vault log`.
    func auditRefusal(event: String, names: [String], by caller: Caller, command: String?) {
        lock.withLock { _ in
            appendAudit(AuditRecord(atMs: millis(), event: event, names: names, by: caller.label, consumer: caller.consumer,
                                    command: command.map(Self.commandSummary), outcome: "not_approved"))
        }
    }

    /// The program a `vault exec` runs, for the audit log: its first word without a folder, at most
    /// 80 characters. Its arguments may hold anything, so they are never logged.
    static func commandSummary(_ command: String) -> String {
        let first = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
        return String((first as NSString).lastPathComponent.prefix(80))
    }

    private struct IndexFile: Codable {
        var version = 1
        var secrets: [String: Entry]
    }

    /// No file is an empty vault; a file that is there but unreadable is an error, so a write
    /// never drops the names it listed.
    private func readIndex() throws -> [String: Entry] {
        let data: Data
        do {
            data = try Data(blockingContentsOf: indexURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        }
        do {
            let file = try JSONDecoder().decode(IndexFile.self, from: data)
            guard file.secrets.keys.allSatisfy(Self.isValidName) else { throw Failure.index(indexURL.path) }
            var entries = file.secrets
            for name in file.secrets.keys {
                // Same-UID agents can change or replay vault.json. Only the current Keychain
                // payload authorizes a release; a missing/legacy item never permits agents.
                entries[name]?.scope = try secrets.record(for: name)?.scope ?? [.user]
            }
            return entries
        } catch {
            throw Failure.index(indexURL.path)
        }
    }

    private func writeIndex(_ secrets: [String: Entry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try ensureFolder()
            try encoder.encode(IndexFile(secrets: secrets)).blockingWrite(to: indexURL, options: [.atomic])
            try FileManager.checked.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
        } catch {
            throw Failure.index(indexURL.path)
        }
    }

    private func ensureFolder() throws {
        try FileManager.checked.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Appends one line (owner-only file); a log that grew past twice ``auditKeep`` is cut back to
    /// its newest ``auditKeep`` lines. An audit write that fails does not undo the work it records.
    private func appendAudit(_ record: AuditRecord) {
        guard var line = try? JSONEncoder().encode(record) else { return }
        line.append(UInt8(ascii: "\n"))
        try? ensureFolder()
        let manager = FileManager.checked
        if !manager.fileExists(atPath: auditURL.path) {
            manager.createFile(atPath: auditURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: auditURL) else { return }
        defer { try? handle.close() }
        guard (try? handle.seekToEnd()) != nil, (try? handle.blockingWrite(contentsOf: line)) != nil else { return }
        guard let size = try? handle.offset(), size > 256 * Self.auditKeep,
              let data = try? Data(blockingContentsOf: auditURL) else { return }
        let lines = data.split(separator: UInt8(ascii: "\n"))
        guard lines.count > 2 * Self.auditKeep else { return }
        var kept = Data(lines.suffix(Self.auditKeep).joined(separator: [UInt8(ascii: "\n")]))
        kept.append(UInt8(ascii: "\n"))
        try? kept.blockingWrite(to: auditURL, options: [.atomic])
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auditURL.path)
    }
}
