import Darwin
import Foundation

extension CodexTurnLedger {
    func incrementUnknownChildCount(_ key: String, in record: inout CodexTurnLedgerRecord) {
        let current = record.unknownChildrenByTurn[key, default: 0]
        record.unknownChildrenByTurn[key] = min(Self.maximumChildrenPerTurn, current + 1)
    }

    func stopChild(id: String?, turnID: String?, in record: inout CodexTurnLedgerRecord) {
        let key = turnKey(turnID ?? record.activeTurnID)
        guard let id = Self.normalized(id), id.utf8.count <= Self.maximumIdentifierBytes else { return }
        var children = record.activeChildrenByTurn[key] ?? []
        children.removeAll { $0 == id }
        if children.isEmpty {
            record.activeChildrenByTurn.removeValue(forKey: key)
        } else {
            record.activeChildrenByTurn[key] = children
        }
        var terminal = record.terminalChildrenByTurn[key] ?? []
        if !terminal.contains(id) { terminal.append(id) }
        record.terminalChildrenByTurn[key] = terminal
    }

    func activeChildCount(_ record: CodexTurnLedgerRecord) -> Int {
        let exact = record.activeChildrenByTurn.values.reduce(0) { $0 + $1.count }
        let unknown = record.unknownChildrenByTurn.values.reduce(0, +)
        return min(Self.maximumChildrenPerTurn * Self.maximumTurnKeys, exact + unknown)
    }

    func activeChildCount(for key: String, in record: CodexTurnLedgerRecord) -> Int {
        let exact = record.activeChildrenByTurn[key]?.count ?? 0
        let unknown = record.unknownChildrenByTurn[key] ?? 0
        return min(Self.maximumChildrenPerTurn, exact + unknown)
    }

    func turnKey(_ turnID: String?) -> String {
        Self.normalized(turnID) ?? "@current"
    }

    func decision(
        ownership: CodexTurnLedgerOwnership,
        settlement: CodexTurnLedgerSettlement,
        activeChildCount: Int,
        turnID: String?,
        shouldNotify: Bool
    ) -> CodexTurnLedgerDecision {
        CodexTurnLedgerDecision(
            ownership: ownership,
            settlement: settlement,
            activeChildCount: max(0, activeChildCount),
            turnID: Self.normalized(turnID),
            shouldNotify: shouldNotify
        )
    }

    func trim(_ record: inout CodexTurnLedgerRecord) {
        let protectedKeys = Set(
            [turnKey(record.activeTurnID)]
                + Array(record.activeChildrenByTurn.keys)
                + Array(record.unknownChildrenByTurn.keys)
                + Array(record.pendingTurns.keys)
        )
        func trimDictionary<T>(_ dictionary: inout [String: T], limit: Int) {
            guard dictionary.count > limit else { return }
            let removableKeys = dictionary.keys
                .filter { !protectedKeys.contains($0) }
                .sorted()
            for key in removableKeys.prefix(dictionary.count - limit) {
                dictionary.removeValue(forKey: key)
            }
        }
        trimDictionary(&record.activeChildrenByTurn, limit: Self.maximumTurnKeys)
        trimDictionary(&record.unknownChildrenByTurn, limit: Self.maximumTurnKeys)
        trimDictionary(&record.terminalChildrenByTurn, limit: Self.maximumTurnKeys)
        trimDictionary(&record.pendingTurns, limit: Self.maximumTurnKeys)
        record.settledTurnIDs = Array(record.settledTurnIDs.suffix(Self.maximumRememberedTurns))
        record.notifiedTurnIDs = Array(record.notifiedTurnIDs.suffix(Self.maximumRememberedTurns))
        for key in record.terminalChildrenByTurn.keys {
            record.terminalChildrenByTurn[key] = Array(
                record.terminalChildrenByTurn[key, default: []].suffix(Self.maximumTerminalChildrenPerTurn)
            )
        }
    }

    func prune(
        _ state: inout CodexTurnLedgerFile,
        retainingAtMost limit: Int = Self.maximumRecords
    ) {
        guard state.records.count > limit else { return }
        let removable = state.records
            .filter {
                $0.value.activeChildrenByTurn.isEmpty
                    && $0.value.unknownChildrenByTurn.isEmpty
                    && $0.value.pendingTurns.isEmpty
            }
            .sorted { $0.value.updatedAt < $1.value.updatedAt }
        let removableIDs = Set(
            removable.prefix(state.records.count - limit).map(\.key)
        )
        for sessionID in removableIDs {
            state.records.removeValue(forKey: sessionID)
        }
        state.surfaceOwners = state.surfaceOwners.filter {
            state.records[$0.value] != nil && !removableIDs.contains($0.value)
        }
    }

    /// Serializes only the cross-process read/modify/atomic-replace transaction;
    /// the lock is released before any socket or UI work begins.
    func withLockedState<T>(
        _ body: (inout CodexTurnLedgerFile) throws -> T
    ) throws -> T {
        let lockPath = path + ".lock"
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let fd = open(lockPath, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard fd >= 0 else {
            throw CLIError(message: "Failed to open Codex turn ledger lock")
        }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else {
            throw CLIError(message: "Failed to lock Codex turn ledger")
        }
        defer { _ = flock(fd, LOCK_UN) }

        var state = try load()
        let result = try body(&state)
        let data = try encoder.encode(state)
        let temporary = parent.appendingPathComponent(
            ".\(parent.lastPathComponent).codex-ledger.\(UUID().uuidString).tmp"
        )
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        ) else {
            throw CLIError(message: "Failed to write Codex turn ledger")
        }
        let renameResult = temporary.path.withCString { source in
            path.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        guard renameResult == 0 else {
            try? fileManager.removeItem(at: temporary)
            throw CLIError(message: "Failed to commit Codex turn ledger")
        }
        return result
    }

    func load() throws -> CodexTurnLedgerFile {
        guard let data = fileManager.contents(atPath: path) else {
            return CodexTurnLedgerFile()
        }
        return (try? decoder.decode(CodexTurnLedgerFile.self, from: data)) ?? CodexTurnLedgerFile()
    }
}
