import CryptoKit
import Foundation

/// The Cloud Secrets vault: secrets by scope, plus a per-machine delivery ledger.
///
/// The vault is write-only from outside. Nothing here returns a stored value except
/// ``plan(machineID:)``, whose ``CloudSecretPlan/toSend`` exists only to feed the
/// end-to-end env delivery in process. Records, changes, ledger entries and status rows
/// carry names and fingerprints only. The vault never logs.
///
/// Every mutation rewrites the whole document through ``CloudSecretVaultStorage``
/// (one Keychain item in production). The document is read once and cached; this actor
/// is the only writer in the process.
public actor CloudSecretVault {
    /// The most secrets the vault holds across all scopes.
    public static let maxSecrets = 500
    /// The most UTF-8 bytes of names and values the vault holds across all scopes, so
    /// the stored document stays a small Keychain item.
    public static let maxTotalBytes = 1_048_576

    private let storage: any CloudSecretVaultStorage
    private let now: @Sendable () -> Date
    private var cached: CloudSecretVaultDocument?
    /// Machines forgotten in this process. A sync that was already in flight when its
    /// machine was destroyed finishes after ``forgetMachine(_:)``; its
    /// ``recordDelivered(machineID:plan:at:)`` or ``recordFailure(machineID:message:)``
    /// must not bring the ledger entry back.
    private var forgottenMachineIDs: Set<String> = []

    public init(storage: any CloudSecretVaultStorage, now: @escaping @Sendable () -> Date = { Date() }) {
        self.storage = storage
        self.now = now
    }

    // MARK: Secrets

    /// Every secret's metadata, sorted by scope rank, scope target, then name.
    public func records() throws -> [CloudSecretRecord] {
        try loadDocument().secrets.map(\.record).sorted(by: Self.recordOrder)
    }

    /// What ``set(_:scope:source:)`` would report for `inputs`, without saving anything.
    /// Validation is the same, so a preview that succeeds means the set will too
    /// (unless the vault changes in between).
    public func preview(_ inputs: [CloudSecretInput], scope: CloudSecretScope) throws -> [CloudSecretChange] {
        try Self.pendingChanges(inputs, scope: scope, document: try loadDocument()).map { $0.change }
    }

    /// Stores `inputs` in `scope`. All inputs are validated before anything is written;
    /// a repeated name in `inputs` keeps its last value. A value equal to the stored one
    /// is reported ``CloudSecretChange/Kind/unchanged`` and keeps its timestamps.
    @discardableResult
    public func set(_ inputs: [CloudSecretInput], scope: CloudSecretScope, source: CloudSecretSource) throws -> [CloudSecretChange] {
        var document = try loadDocument()
        let pending = try Self.pendingChanges(inputs, scope: scope, document: document)
        guard pending.contains(where: { $0.change.kind != .unchanged }) else { return pending.map { $0.change } }
        let key = ensureKey(in: &document)
        let timestamp = now()
        for item in pending {
            let name = item.change.name
            let fingerprint = Self.fingerprint(item.value, key: key)
            switch item.change.kind {
            case .unchanged, .removed:
                continue
            case .updated:
                guard let index = Self.secretIndex(name, scope: scope, in: document) else { continue }
                let existing = document.secrets[index].record
                document.secrets[index] = CloudSecretVaultDocument.Entry(
                    record: CloudSecretRecord(
                        name: name,
                        scope: scope,
                        fingerprint: fingerprint,
                        createdAt: existing.createdAt,
                        updatedAt: timestamp,
                        source: source
                    ),
                    value: item.value
                )
            case .added:
                document.secrets.append(CloudSecretVaultDocument.Entry(
                    record: CloudSecretRecord(
                        name: name,
                        scope: scope,
                        fingerprint: fingerprint,
                        createdAt: timestamp,
                        updatedAt: timestamp,
                        source: source
                    ),
                    value: item.value
                ))
            }
        }
        try persist(document)
        return pending.map { $0.change }
    }

    /// Removes `names` from `scope`. Names not stored there are skipped and not reported.
    @discardableResult
    public func remove(names: [String], scope: CloudSecretScope) throws -> [CloudSecretChange] {
        var document = try loadDocument()
        var changes: [CloudSecretChange] = []
        for name in names {
            guard let index = Self.secretIndex(name, scope: scope, in: document) else { continue }
            document.secrets.remove(at: index)
            changes.append(CloudSecretChange(name: name, scope: scope, kind: .removed))
        }
        if !changes.isEmpty { try persist(document) }
        return changes
    }

    // MARK: Machines

    /// Links `machineID` to `projectKey`, so that project's scope applies to it.
    public func linkMachine(_ machineID: String, projectKey: String) throws {
        var document = try loadDocument()
        if let existing = Self.ledgerEntry(machineID, in: document), existing.projectKeys.contains(projectKey) { return }
        var entry = Self.ledgerEntry(machineID, in: document) ?? CloudSecretDelivery(machineID: machineID)
        entry.projectKeys.append(projectKey)
        Self.upsert(entry, in: &document)
        try persist(document)
    }

    /// Unlinks `machineID` from `projectKey`. A no-op when they were not linked.
    public func unlinkMachine(_ machineID: String, projectKey: String) throws {
        var document = try loadDocument()
        guard var entry = Self.ledgerEntry(machineID, in: document), entry.projectKeys.contains(projectKey) else { return }
        entry.projectKeys.removeAll { $0 == projectKey }
        Self.upsert(entry, in: &document)
        try persist(document)
    }

    /// The ledger entry for one machine, `nil` when it was never linked or synced.
    public func delivery(for machineID: String) throws -> CloudSecretDelivery? {
        Self.ledgerEntry(machineID, in: try loadDocument())
    }

    /// Every ledger entry, sorted by machine ID.
    public func deliveries() throws -> [CloudSecretDelivery] {
        try loadDocument().ledger.sorted { $0.machineID < $1.machineID }
    }

    /// Machine IDs in the ledger whose plan is not a no-op, sorted.
    public func machinesNeedingSync() throws -> [String] {
        let document = try loadDocument()
        return document.ledger
            .map(\.machineID)
            .filter { !Self.plan(machineID: $0, document: document).isNoop }
            .sorted()
    }

    /// Forgets a destroyed machine: its ledger entry and its machine-scoped secrets.
    /// Later delivery records for the machine are ignored.
    public func forgetMachine(_ machineID: String) throws {
        forgottenMachineIDs.insert(machineID)
        var document = try loadDocument()
        let before = document
        document.ledger.removeAll { $0.machineID == machineID }
        document.secrets.removeAll { $0.record.scope == .machine(machineID) }
        if document != before { try persist(document) }
    }

    // MARK: Sync

    /// What a sync of `machineID` should do now.
    ///
    /// The effective set is the union of the `all` scope, every linked project's scope and
    /// the machine's own scope; on a name clash the most specific scope wins (and between
    /// two projects, the earlier link). When any effective fingerprint differs from the
    /// ledger, or the delivered names differ, the whole effective set is sent: the
    /// receiver merges, so a full send is always safe. Names delivered earlier that no
    /// longer apply are removed.
    public func plan(machineID: String) throws -> CloudSecretPlan {
        Self.plan(machineID: machineID, document: try loadDocument())
    }

    /// Records a successful delivery of `plan`: the ledger now holds the plan's
    /// fingerprints, and the machine's last error is cleared. Ignored for a machine
    /// forgotten since the plan was made.
    public func recordDelivered(machineID: String, plan: CloudSecretPlan, at: Date) throws {
        guard plan.machineID == machineID else {
            throw CloudSecretVaultError.planMachineMismatch(expected: machineID, actual: plan.machineID)
        }
        guard !forgottenMachineIDs.contains(machineID) else { return }
        var document = try loadDocument()
        var entry = Self.ledgerEntry(machineID, in: document) ?? CloudSecretDelivery(machineID: machineID)
        let removed = Set(plan.toRemove)
        entry.delivered = entry.delivered.filter { !removed.contains($0.key) }
        // A provider guard may hold back part of a full plan while the other
        // entries are delivered. Merge the successful names into the existing
        // ledger so a held-back key remains tracked for a later retry or revoke.
        for name in plan.sendNames {
            if let fingerprint = plan.fingerprints[name] {
                entry.delivered[name] = fingerprint
            }
        }
        entry.deliveredAt = at
        entry.lastError = nil
        Self.upsert(entry, in: &document)
        try persist(document)
    }

    /// Records a failed sync. `message` must already be redacted. Ignored for a
    /// forgotten machine.
    public func recordFailure(machineID: String, message: String) throws {
        guard !forgottenMachineIDs.contains(machineID) else { return }
        var document = try loadDocument()
        var entry = Self.ledgerEntry(machineID, in: document) ?? CloudSecretDelivery(machineID: machineID)
        entry.lastError = message
        Self.upsert(entry, in: &document)
        try persist(document)
    }

    /// Per-name state on `machineID`, sorted by name.
    ///
    /// - Parameter namesOnMachine: The names the machine's env file holds, when the caller
    ///   verified them (names only, from `cmux env`). An effective name absent from it is
    ///   ``CloudSecretMachineState/missing`` even if the ledger says it was delivered; a
    ///   vault name present on the machine but not effective for it is
    ///   ``CloudSecretMachineState/extra``. Names the vault has never held are the
    ///   machine's own and are not reported.
    public func status(machineID: String, namesOnMachine: Set<String>?) throws -> [CloudSecretMachineStatusRow] {
        let document = try loadDocument()
        let effective = Self.effectiveEntries(machineID: machineID, document: document)
        let delivered = Self.ledgerEntry(machineID, in: document)?.delivered ?? [:]
        var rows: [CloudSecretMachineStatusRow] = []
        for (name, entry) in effective {
            let fingerprint = entry.record.fingerprint
            let state: CloudSecretMachineState
            if let namesOnMachine, !namesOnMachine.contains(name) {
                state = .missing
            } else if let deliveredFingerprint = delivered[name] {
                state = deliveredFingerprint == fingerprint ? .current : .stale
            } else {
                state = .missing
            }
            rows.append(CloudSecretMachineStatusRow(name: name, scope: entry.record.scope, state: state, fingerprint: fingerprint))
        }
        var extra = Set(delivered.keys)
        if let namesOnMachine {
            let vaultNames = Set(document.secrets.map(\.record.name))
            extra.formUnion(namesOnMachine.intersection(vaultNames))
        }
        for name in extra where effective[name] == nil {
            rows.append(CloudSecretMachineStatusRow(name: name, scope: nil, state: .extra, fingerprint: delivered[name]))
        }
        return rows.sorted { $0.name < $1.name }
    }

    // MARK: Fingerprints

    /// First 8 hex characters of HMAC-SHA256(`key`, UTF-8 `value`).
    static func fingerprint(_ value: String, key: SymmetricKey) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key)
        return Data(code).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Internals

    private func loadDocument() throws -> CloudSecretVaultDocument {
        if let cached { return cached }
        let loaded: CloudSecretVaultDocument
        if let data = try storage.load() {
            loaded = try CloudSecretVaultDocument.decode(data)
        } else {
            loaded = CloudSecretVaultDocument()
        }
        cached = loaded
        return loaded
    }

    private func persist(_ document: CloudSecretVaultDocument) throws {
        var document = document
        document.version = CloudSecretVaultDocument.currentVersion
        try storage.save(try document.encoded())
        cached = document
    }

    /// The fingerprint key, created (32 random bytes) the first time it is needed.
    private func ensureKey(in document: inout CloudSecretVaultDocument) -> SymmetricKey {
        if let data = Data(base64Encoded: document.hmacKey), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        document.hmacKey = key.withUnsafeBytes { Data($0) }.base64EncodedString()
        return key
    }

    static func plan(machineID: String, document: CloudSecretVaultDocument) -> CloudSecretPlan {
        let effective = effectiveEntries(machineID: machineID, document: document)
        let fingerprints = effective.mapValues(\.record.fingerprint)
        let delivered = ledgerEntry(machineID, in: document)?.delivered ?? [:]
        let toSend: [CloudEnvDelivery.Entry]
        if fingerprints == delivered {
            toSend = []
        } else {
            toSend = effective.keys.sorted().compactMap { name in
                effective[name].map { CloudEnvDelivery.Entry(key: name, value: $0.value) }
            }
        }
        let toRemove = delivered.keys.filter { effective[$0] == nil }.sorted()
        return CloudSecretPlan(
            machineID: machineID,
            toSend: toSend,
            toRemove: toRemove,
            effective: effective.mapValues(\.record.scope),
            fingerprints: fingerprints
        )
    }

    /// The secrets that apply to `machineID`, by name. A name stored before it became
    /// reserved (``CloudSecretInput/isReservedName(_:)``) never applies: the machine
    /// refuses it, so it is not sent, and a copy delivered earlier is removed.
    static func effectiveEntries(machineID: String, document: CloudSecretVaultDocument) -> [String: CloudSecretVaultDocument.Entry] {
        let projectKeys = ledgerEntry(machineID, in: document)?.projectKeys ?? []
        // Least specific first, so later scopes overwrite; earlier project links win.
        let scopes: [CloudSecretScope] = [.all] + projectKeys.reversed().map { CloudSecretScope.project($0) } + [.machine(machineID)]
        var effective: [String: CloudSecretVaultDocument.Entry] = [:]
        for scope in scopes {
            for entry in document.secrets where entry.record.scope == scope && !CloudSecretInput.isReservedName(entry.record.name) {
                effective[entry.record.name] = entry
            }
        }
        return effective
    }

    static func ledgerEntry(_ machineID: String, in document: CloudSecretVaultDocument) -> CloudSecretDelivery? {
        document.ledger.first { $0.machineID == machineID }
    }

    static func upsert(_ entry: CloudSecretDelivery, in document: inout CloudSecretVaultDocument) {
        if let index = document.ledger.firstIndex(where: { $0.machineID == entry.machineID }) {
            document.ledger[index] = entry
        } else {
            document.ledger.append(entry)
        }
    }

    /// Validates `inputs` and compares them with what `scope` holds: one change per
    /// distinct name, in first-appearance order, carrying the name's last value.
    /// Shared by ``preview(_:scope:)`` and ``set(_:scope:source:)``.
    static func pendingChanges(
        _ inputs: [CloudSecretInput],
        scope: CloudSecretScope,
        document: CloudSecretVaultDocument
    ) throws -> [(change: CloudSecretChange, value: String)] {
        for input in inputs { try input.validate() }
        var latest: [String: String] = [:]
        var order: [String] = []
        for input in inputs {
            if latest[input.name] == nil { order.append(input.name) }
            latest[input.name] = input.value
        }
        var pending: [(change: CloudSecretChange, value: String)] = []
        var addedCount = 0
        for name in order {
            guard let value = latest[name] else { continue }
            let kind: CloudSecretChange.Kind
            if let index = secretIndex(name, scope: scope, in: document) {
                kind = document.secrets[index].value == value ? .unchanged : .updated
            } else {
                kind = .added
                addedCount += 1
            }
            pending.append((change: CloudSecretChange(name: name, scope: scope, kind: kind), value: value))
        }
        guard document.secrets.count + addedCount <= maxSecrets else {
            throw CloudSecretValidationError.tooMany
        }
        // The total after the change: a replaced value no longer counts.
        let replaced = Set(pending.map(\.change.name))
        let kept = document.secrets.filter { $0.record.scope != scope || !replaced.contains($0.record.name) }
        let total = kept.reduce(0) { $0 + $1.record.name.utf8.count + $1.value.utf8.count }
            + pending.reduce(0) { $0 + $1.change.name.utf8.count + $1.value.utf8.count }
        guard total <= maxTotalBytes else {
            throw CloudSecretValidationError.vaultTooLarge
        }
        return pending
    }

    static func secretIndex(_ name: String, scope: CloudSecretScope, in document: CloudSecretVaultDocument) -> Int? {
        document.secrets.firstIndex { $0.record.name == name && $0.record.scope == scope }
    }

    static func recordOrder(_ lhs: CloudSecretRecord, _ rhs: CloudSecretRecord) -> Bool {
        if lhs.scope.rank != rhs.scope.rank { return lhs.scope.rank < rhs.scope.rank }
        if lhs.scope.target != rhs.scope.target { return lhs.scope.target < rhs.scope.target }
        return lhs.name < rhs.name
    }
}
