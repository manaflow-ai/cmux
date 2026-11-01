import CMUXAgentLaunch
import Darwin
import Foundation

/// One Claude session's automatic-difficulty history.
struct ClaudeDifficultyAssessmentEntry: Codable, Equatable, Sendable {
    /// When the last assessment finished, whatever its outcome.
    var lastAssessedAt: TimeInterval?
    /// When the assessment now running started; `nil` while none runs.
    var inFlightAt: TimeInterval?
    /// The verdict of the session's last assessment that produced one, sent or
    /// not (a `ClaudeSessionDifficulty` raw value).
    var lastVerdict: String?
    var updatedAt: TimeInterval
}

struct ClaudeDifficultyAssessmentStoreFile: Codable, Equatable, Sendable {
    var version = 1
    var sessions: [String: ClaudeDifficultyAssessmentEntry] = [:]
}

/// What `begin` decided, and the session's previous verdict for damping.
struct ClaudeDifficultyAssessmentStart: Equatable, Sendable {
    var decision: DifficultyAssessmentDecision
    var previousVerdict: ClaudeSessionDifficulty?
}

/// Per-session throttle and verdict history of the automatic difficulty pass.
///
/// Kept apart from the hook session store on purpose: `SessionEnd` removes a
/// session's hook record, and every restart cmux makes for a new effort ends
/// the Claude process. Entries here are keyed by session id, outlive that, and
/// are dropped once untouched for `DifficultyAssessmentConfig.storeRetention`.
/// Every mutation is one transaction under an exclusive file lock, like the
/// hook session store; the lock is never held across the rating call.
final class ClaudeDifficultyAssessmentStore {
    static let filename = "claude-difficulty-assessments.json"
    /// A larger file is not a store this pass wrote; it is replaced, not read.
    private static let maxFileBytes = 1024 * 1024

    let path: String
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Lives next to the hook session store: in the directory of
    /// `CMUX_CLAUDE_HOOK_STATE_PATH`, else in `CMUX_AGENT_HOOK_STATE_DIR`, else
    /// in `~/.cmuxterm`.
    init(
        processEnv: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        func override(_ key: String) -> String? {
            guard let value = processEnv[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return NSString(string: value).expandingTildeInPath
        }
        let directory: URL
        if let hookStatePath = override("CMUX_CLAUDE_HOOK_STATE_PATH") {
            directory = URL(fileURLWithPath: hookStatePath).deletingLastPathComponent()
        } else if let stateDirectory = override("CMUX_AGENT_HOOK_STATE_DIR") {
            directory = URL(fileURLWithPath: stateDirectory, isDirectory: true)
        } else {
            directory = URL(fileURLWithPath: NSString(string: "~/.cmuxterm").expandingTildeInPath, isDirectory: true)
        }
        self.path = directory.appendingPathComponent(Self.filename, isDirectory: false).path
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    /// Evaluates the throttle and, on `.proceed`, marks the session in flight
    /// in the same transaction.
    func begin(sessionId: String, now: Date) throws -> ClaudeDifficultyAssessmentStart {
        let key = Self.normalized(sessionId)
        guard !key.isEmpty else { return ClaudeDifficultyAssessmentStart(decision: .skipTooSoon, previousVerdict: nil) }
        let t = now.timeIntervalSince1970
        return try withLockedState(now: now) { state in
            var entry = state.sessions[key] ?? ClaudeDifficultyAssessmentEntry(updatedAt: t)
            let decision = DifficultyAssessmentEngine.throttleDecision(
                inFlightAt: entry.inFlightAt,
                lastAssessedAt: entry.lastAssessedAt,
                now: now
            )
            if decision == .proceed {
                entry.inFlightAt = t
                entry.updatedAt = t
                state.sessions[key] = entry
            }
            return ClaudeDifficultyAssessmentStart(
                decision: decision,
                previousVerdict: entry.lastVerdict.flatMap(ClaudeSessionDifficulty.init(rawValue:))
            )
        }
    }

    /// Ends the running assessment: stamps the attempt time (success or
    /// failure, so a failing call is not retried every turn) and records the
    /// verdict when there is one. `nil` keeps the previous verdict.
    func finish(sessionId: String, verdict: ClaudeSessionDifficulty?, now: Date) throws {
        let key = Self.normalized(sessionId)
        guard !key.isEmpty else { return }
        let t = now.timeIntervalSince1970
        try withLockedState(now: now) { state in
            var entry = state.sessions[key] ?? ClaudeDifficultyAssessmentEntry(updatedAt: t)
            entry.inFlightAt = nil
            entry.lastAssessedAt = t
            if let verdict { entry.lastVerdict = verdict.rawValue }
            entry.updatedAt = t
            state.sessions[key] = entry
        }
    }

    /// The session's entry as stored, without changing anything.
    func entry(sessionId: String) throws -> ClaudeDifficultyAssessmentEntry? {
        let key = Self.normalized(sessionId)
        guard !key.isEmpty else { return nil }
        return try withLockedState(now: Date(), persist: false) { $0.sessions[key] }
    }

    private static func normalized(_ sessionId: String) -> String {
        sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs one read/modify/atomic-replace transaction under the store's lock;
    /// a persisting transaction first drops entries older than the retention.
    private func withLockedState<T>(
        now: Date,
        persist: Bool = true,
        _ body: (inout ClaudeDifficultyAssessmentStoreFile) throws -> T
    ) throws -> T {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let lockPath = path + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard fd >= 0 else { throw StoreError(message: "Failed to open difficulty store lock: \(lockPath)") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else {
            throw StoreError(message: "Failed to lock difficulty store: \(lockPath)")
        }
        defer { _ = flock(fd, LOCK_UN) }

        var state = load()
        let result = try body(&state)
        guard persist else { return result }
        let cutoff = now.timeIntervalSince1970 - DifficultyAssessmentConfig.storeRetention
        state.sessions = state.sessions.filter { $0.value.updatedAt >= cutoff }
        try save(state, in: parent)
        return result
    }

    private func load() -> ClaudeDifficultyAssessmentStoreFile {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size <= Self.maxFileBytes,
              let data = fileManager.contents(atPath: path),
              let decoded = try? decoder.decode(ClaudeDifficultyAssessmentStoreFile.self, from: data) else {
            return ClaudeDifficultyAssessmentStoreFile()
        }
        return decoded
    }

    private func save(_ state: ClaudeDifficultyAssessmentStoreFile, in parent: URL) throws {
        let data = try encoder.encode(state)
        let temporary = parent.appendingPathComponent(".\(Self.filename).\(UUID().uuidString).tmp")
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        ) else {
            throw StoreError(message: "Failed to write difficulty store: \(path)")
        }
        let renamed = temporary.path.withCString { source in
            path.withCString { destination in Darwin.rename(source, destination) }
        }
        guard renamed == 0 else {
            try? fileManager.removeItem(at: temporary)
            throw StoreError(message: "Failed to commit difficulty store: \(path)")
        }
    }

    private struct StoreError: Error {
        let message: String
    }
}
