import Darwin
import Foundation

extension CodexTurnLedger {
    func activeChildCount(_ record: CodexTurnLedgerRecord) -> Int {
        let exact = record.activeChildrenByTurn.values.reduce(0) { $0 + $1.count }
        let unknown = record.unknownChildrenByTurn.values.reduce(0, +)
        return exact + unknown
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
        func trimDictionary<T>(_ dictionary: inout [String: T], limit: Int) {
            guard dictionary.count > limit else { return }
            let keys = dictionary.keys.sorted()
            for key in keys.prefix(dictionary.count - limit) {
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

    func prune(_ state: inout CodexTurnLedgerFile) {
        guard state.records.count > Self.maximumRecords else { return }
        let removable = state.records
            .filter {
                $0.value.activeChildrenByTurn.isEmpty
                    && $0.value.unknownChildrenByTurn.isEmpty
                    && $0.value.pendingTurns.isEmpty
            }
            .sorted { $0.value.updatedAt < $1.value.updatedAt }
        for (sessionID, _) in removable.prefix(state.records.count - Self.maximumRecords) {
            state.records.removeValue(forKey: sessionID)
            state.surfaceOwners = state.surfaceOwners.filter { $0.value != sessionID }
        }
    }

    func withLockedState<T>(
        _ body: (inout CodexTurnLedgerFile) throws -> T
    ) throws -> T {
        let lockPath = path + ".lock"
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
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
        guard let state = try? decoder.decode(CodexTurnLedgerFile.self, from: data) else {
            throw CLIError(message: "Codex turn ledger is corrupt")
        }
        return state
    }
}
