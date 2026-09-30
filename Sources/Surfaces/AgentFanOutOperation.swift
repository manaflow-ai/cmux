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
    var terminalID: String?
    var state: AgentFanOutChildState
    var exitCode: Int?
    var errorCode: String?
    var startedAt: Date?
    var endedAt: Date?

    var foundationObject: [String: Any] {
        var result: [String: Any] = ["index": index, "state": state.rawValue]
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
    let remoteWorkspaceID: String
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

    var foundationObject: [String: Any] {
        [
            "operation_id": id,
            "machine": machineID,
            "remote_workspace_id": remoteWorkspaceID,
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

    static func digest(argv: [String]) -> String {
        // CryptoKit is available in the macOS target.  Keep the operation model
        // independent of Foundation's locale/encoding details.
        let bytes = argv.joined(separator: "\u{0}").data(using: .utf8) ?? Data()
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

    private var fileURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return base.appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("agent-fan-out-operations.json", isDirectory: false)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder.cmuxAgentFanOut.decode([String: AgentFanOutOperation].self, from: data) else { return }
        operations = saved
    }

    private func persist() {
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder.cmuxAgentFanOut.encode(operations) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func operation(id: String) -> AgentFanOutOperation? {
        loadIfNeeded()
        return operations[id]
    }

    /// Returns false when the id was already present.  Callers must compare the
    /// immutable request fields before reusing an existing operation.
    func insertIfAbsent(_ operation: AgentFanOutOperation) -> Bool {
        loadIfNeeded()
        guard operations[operation.id] == nil else { return false }
        operations[operation.id] = operation
        persist()
        return true
    }

    func update(_ operation: AgentFanOutOperation) {
        loadIfNeeded()
        operations[operation.id] = operation
        persist()
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
