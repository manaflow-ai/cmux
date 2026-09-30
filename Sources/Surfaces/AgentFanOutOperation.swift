import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The durable identity of one group of agent terminals.  The operation keeps
/// only a digest of the command: prompts remain in the terminal's own durable
/// scrollback and are never copied into the operation ledger.
enum AgentFanOutOperationState: String, Codable {
    case creating
    case running
    case partial
    case completed
    case failed
}

enum AgentFanOutChildState: String, Codable {
    case starting
    case running
    case exited
    case failed
}

struct AgentFanOutChild: Codable, Equatable {
    let index: Int
    /// Each default fan-out child gets its own remote workspace so the local
    /// sidebar can project it as an independently visible workspace. Older
    /// ledgers omit this field and continue to decode safely.
    var remoteWorkspaceID: String?
    /// The local workspace created for a visible child, when one was opened.
    var localWorkspaceID: String?
    /// A local open can fail while the remote child continues running.
    var projectionErrorCode: String?
    var terminalID: String?
    var state: AgentFanOutChildState
    var exitCode: Int?
    var errorCode: String?
    var startedAt: Date?
    var endedAt: Date?

    init(
        index: Int,
        remoteWorkspaceID: String? = nil,
        localWorkspaceID: String? = nil,
        projectionErrorCode: String? = nil,
        terminalID: String?,
        state: AgentFanOutChildState,
        exitCode: Int?,
        errorCode: String?,
        startedAt: Date?,
        endedAt: Date?
    ) {
        self.index = index
        self.remoteWorkspaceID = remoteWorkspaceID
        self.localWorkspaceID = localWorkspaceID
        self.projectionErrorCode = projectionErrorCode
        self.terminalID = terminalID
        self.state = state
        self.exitCode = exitCode
        self.errorCode = errorCode
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    var foundationObject: [String: Any] {
        var result: [String: Any] = ["index": index, "state": state.rawValue]
        if let remoteWorkspaceID { result["remote_workspace_id"] = remoteWorkspaceID }
        if let localWorkspaceID { result["local_workspace_id"] = localWorkspaceID }
        if let projectionErrorCode { result["projection_error_code"] = projectionErrorCode }
        if let terminalID { result["terminal_id"] = terminalID }
        if let exitCode { result["exit_code"] = exitCode }
        if let errorCode { result["error_code"] = errorCode }
        if let startedAt { result["started_at"] = ISO8601DateFormatter().string(from: startedAt) }
        if let endedAt { result["ended_at"] = ISO8601DateFormatter().string(from: endedAt) }
        return result
    }
}

struct AgentFanOutOperation: Codable, Equatable {
    static let maximumCount = 32

    let id: String
    let machineID: String
    /// Authenticated Cloud team/account boundary.  This is an opaque id and is
    /// used only to prevent a later signed-in user from observing old records.
    let scope: String
    /// Empty while the operation is reserving its remote workspace. Keeping a
    /// placeholder record before that network mutation closes the duplicate-ID
    /// race; the owner fills this in once the workspace receipt commits.
    var remoteWorkspaceID: String
    let agent: String
    /// SHA-256 of the argv bytes joined with NUL separators.  This lets a retry
    /// prove it is the same request without persisting the prompt itself.
    let argvDigest: String
    let requestedCount: Int
    let createdAt: Date
    var updatedAt: Date
    var state: AgentFanOutOperationState
    var children: [AgentFanOutChild]

    var createdCount: Int { children.filter { $0.terminalID != nil }.count }
    var settledCount: Int { children.filter { $0.state == .exited || $0.state == .failed }.count }
    var remoteWorkspaceIDs: [String] {
        var seen = Set<String>()
        return children.compactMap(\.remoteWorkspaceID).filter { seen.insert($0).inserted }
    }

    var foundationObject: [String: Any] {
        [
            "operation_id": id,
            "machine": machineID,
            "remote_workspace_id": remoteWorkspaceID,
            "remote_workspace_ids": remoteWorkspaceIDs,
            "agent": agent,
            "requested": requestedCount,
            "created": createdCount,
            "settled": settledCount,
            "state": state.rawValue,
            "created_at": ISO8601DateFormatter().string(from: createdAt),
            "updated_at": ISO8601DateFormatter().string(from: updatedAt),
            "children": children.map(\.foundationObject),
        ]
    }

    static func digest(argv: [String], identity: [String: String] = [:]) -> String {
        // CryptoKit is available in the macOS target. Keep the operation model
        // independent of Foundation's locale/encoding details. Sorting keeps
        // dictionary iteration order from changing idempotency keys.
        let identityBytes = identity.keys.sorted().map { "\($0)=\(identity[$0] ?? "")" }
        let bytes = (argv + ["--cmux-request-identity--"] + identityBytes)
            .joined(separator: "\u{0}").data(using: .utf8) ?? Data()
        #if canImport(CryptoKit)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #else
        // Linux static verification does not link CryptoKit.  This fallback is
        // deterministic and is replaced by SHA-256 on the app target.
        var hash: UInt64 = 14695981039346656037
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(format: "%016llx", hash)
        #endif
    }

    static func validate(machineID: String, agent: String, argv: [String], count: Int) -> String? {
        guard !machineID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "machine is required" }
        guard ["claude", "codex", "opencode", "pi"].contains(agent) else { return "unsupported agent '\(agent)'" }
        guard !argv.isEmpty else { return "argv must not be empty" }
        guard (1...maximumCount).contains(count) else { return "count must be between 1 and \(maximumCount)" }
        return nil
    }

    mutating func recomputeState(now: Date = Date()) {
        updatedAt = now
        if children.allSatisfy({ $0.state == .exited }) {
            state = .completed
        } else if children.allSatisfy({ $0.state == .failed }) {
            state = .failed
        } else if children.contains(where: { $0.state == .failed }) {
            state = .partial
        } else if children.contains(where: { $0.state == .running || $0.state == .starting }) {
            state = .running
        } else {
            state = .partial
        }
    }
}

/// A small actor-backed operation ledger.  Socket workers can create and
/// inspect operations concurrently without racing a retry or corrupting the
/// on-disk snapshot.  The daemon remains the owner of terminal processes; this
/// ledger records the app's idempotent request and the returned terminal ids.
actor AgentFanOutOperationStore {
    static let shared = AgentFanOutOperationStore()

    private var operations: [String: AgentFanOutOperation] = [:]
    private var loaded = false
    private var loadFailure: Error?
    private let configuredFileURL: URL?

    init(fileURL: URL? = nil) {
        configuredFileURL = fileURL
    }

    private var fileURL: URL {
        if let configuredFileURL { return configuredFileURL }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return base.appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("agent-fan-out-operations.json", isDirectory: false)
    }

    private func loadIfNeeded() throws {
        guard !loaded else {
            if let loadFailure { throw loadFailure }
            return
        }
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            operations = try JSONDecoder.cmuxAgentFanOut.decode([String: AgentFanOutOperation].self, from: data)
        } catch {
            // A corrupt ledger must be visible to the caller. Treating it as an
            // empty store would allow a retry to create duplicate work.
            loadFailure = error
            throw error
        }
    }

    private func persist() throws {
        let url = fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.cmuxAgentFanOut.encode(operations)
        try data.write(to: url, options: .atomic)
    }

    func operation(id: String) throws -> AgentFanOutOperation? {
        try loadIfNeeded()
        return operations[id]
    }

    /// Returns false when the id was already present.  Callers must compare the
    /// immutable request fields before reusing an existing operation.
    func insertIfAbsent(_ operation: AgentFanOutOperation) throws -> Bool {
        try loadIfNeeded()
        guard operations[operation.id] == nil else { return false }
        operations[operation.id] = operation
        do {
            try persist()
        } catch {
            operations.removeValue(forKey: operation.id)
            throw error
        }
        return true
    }

    /// Merge an observation into the durable record. A creator may be holding
    /// a stale snapshot while a status waiter records an exited child; terminal
    /// child identities always win over a stale starting/running observation.
    func update(_ incoming: AgentFanOutOperation) throws {
        try loadIfNeeded()
        let previous = operations[incoming.id]
        var merged = incoming
        if let previous {
            merged.remoteWorkspaceID = incoming.remoteWorkspaceID.isEmpty ? previous.remoteWorkspaceID : incoming.remoteWorkspaceID
            merged.children = incoming.children.map { candidate in
                guard let current = previous.children.first(where: { $0.index == candidate.index }) else { return candidate }
                var candidate = candidate
                if candidate.remoteWorkspaceID == nil {
                    candidate.remoteWorkspaceID = current.remoteWorkspaceID
                }
                if candidate.localWorkspaceID == nil {
                    candidate.localWorkspaceID = current.localWorkspaceID
                }
                if candidate.projectionErrorCode == nil {
                    candidate.projectionErrorCode = current.projectionErrorCode
                }
                if current.state == .exited {
                    return current
                }
                if current.state == .failed,
                   candidate.state == .starting || candidate.state == .running {
                    return current
                }
                if current.terminalID != nil && candidate.terminalID == nil {
                    return current
                }
                return candidate
            }
            merged.recomputeState(now: max(incoming.updatedAt, previous.updatedAt))
        }
        operations[incoming.id] = merged
        do {
            try persist()
        } catch {
            if let previous { operations[incoming.id] = previous } else { operations.removeValue(forKey: incoming.id) }
            throw error
        }
    }

    /// Apply terminal observations without replacing fields written by a
    /// concurrent creator. Refreshers may hold a stale snapshot while they
    /// await the provider, so only a still-running child with the same
    /// terminal identity can transition to exited here.
    func mergeTerminalExits(_ refreshed: AgentFanOutOperation) throws -> AgentFanOutOperation? {
        try loadIfNeeded()
        guard operations[refreshed.id] != nil else { return nil }
        try update(refreshed)
        return operations[refreshed.id]
    }
}

private extension JSONEncoder {
    static var cmuxAgentFanOut: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var cmuxAgentFanOut: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
