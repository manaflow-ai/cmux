import Foundation

/// The process identity carried by one Codex hook invocation.
///
/// CMUX_CODEX_PID is a launch-time claim and is inherited by descendants.
/// The hook shell also supplies CMUX_CODEX_HOOK_PID, identifying the process
/// that actually caused the callback.
struct CodexHookInvocation: Equatable, Sendable {
    static let tokenEnvironmentKey = "CMUX_CODEX_INVOCATION_ID"
    static let parentTokenEnvironmentKey = "CMUX_CODEX_PARENT_INVOCATION_ID"
    static let ownerPIDEnvironmentKey = "CMUX_CODEX_PID"
    static let observedPIDEnvironmentKey = "CMUX_CODEX_HOOK_PID"
    static let ledgerPathEnvironmentKey = "CMUX_CODEX_TURN_LEDGER_PATH"

    let token: String?
    let parentToken: String?
    let ownerPID: Int?
    let observedPID: Int?
    let ownerGeneration: CodexProcessGeneration?
    let observedGeneration: CodexProcessGeneration?
    let hasNestedAgentAncestor: Bool

    init(
        environment: [String: String],
        fallbackObservedPID: Int? = Int(getppid()),
        hasNestedAgentAncestor: Bool = false
    ) {
        token = Self.normalized(environment[Self.tokenEnvironmentKey])
        parentToken = Self.normalized(environment[Self.parentTokenEnvironmentKey])
        ownerPID = Self.positivePID(environment[Self.ownerPIDEnvironmentKey])
        observedPID = Self.positivePID(environment[Self.observedPIDEnvironmentKey])
            ?? fallbackObservedPID.flatMap { $0 > 0 ? $0 : nil }
        ownerGeneration = ownerPID.flatMap { CodexProcessGeneration(pid: $0) }
        observedGeneration = observedPID.flatMap { CodexProcessGeneration(pid: $0) }
        self.hasNestedAgentAncestor = hasNestedAgentAncestor
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= 128,
              value.unicodeScalars.allSatisfy({
                  $0.isASCII && !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return value
    }

    private static func positivePID(_ value: String?) -> Int? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int(value),
              pid > 0,
              pid <= Int(Int32.max) else {
            return nil
        }
        return pid
    }
}

/// Exact kernel process generation used by the Codex ownership ledger.
struct CodexProcessGeneration: Codable, Equatable, Comparable, Sendable {
    let pid: Int
    let startSeconds: Int64
    let startMicroseconds: Int64

    init(pid: Int, startSeconds: Int64, startMicroseconds: Int64) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }

    init?(pid: Int) {
        guard let identity = AgentPIDProcessIdentity(pid: pid_t(pid)) else { return nil }
        self.init(
            pid: Int(identity.pid),
            startSeconds: identity.startSeconds,
            startMicroseconds: identity.startMicroseconds
        )
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.startSeconds != rhs.startSeconds { return lhs.startSeconds < rhs.startSeconds }
        if lhs.startMicroseconds != rhs.startMicroseconds { return lhs.startMicroseconds < rhs.startMicroseconds }
        return lhs.pid < rhs.pid
    }
}

enum CodexTurnLedgerOwnership: Equatable, Sendable {
    case foreground
    case nested
    case unknown
}

enum CodexTurnLedgerSettlement: Equatable, Sendable {
    case none
    case pending
    case settled
    case duplicate
}

struct CodexTurnLedgerDecision: Equatable, Sendable {
    let ownership: CodexTurnLedgerOwnership
    let settlement: CodexTurnLedgerSettlement
    let activeChildCount: Int
    let turnID: String?
    let shouldNotify: Bool

    static let ignored = Self(
        ownership: .unknown,
        settlement: .none,
        activeChildCount: 0,
        turnID: nil,
        shouldNotify: false
    )
}

struct CodexTurnLedgerOwner: Codable, Equatable {
    var token: String?
    var pid: Int?
    var generation: CodexProcessGeneration?
}

struct CodexTurnLedgerPending: Codable, Equatable {
    let turnID: String?
}

struct CodexTurnLedgerRecord: Codable, Equatable {
    var workspaceID: String
    var surfaceID: String
    var owner: CodexTurnLedgerOwner
    var activeTurnID: String?
    var activeChildrenByTurn: [String: [String]]
    var unknownChildrenByTurn: [String: Int]
    var terminalChildrenByTurn: [String: [String]]
    var pendingTurns: [String: CodexTurnLedgerPending]
    var settledTurnIDs: [String]
    var notifiedTurnIDs: [String]
    var updatedAt: TimeInterval
}

struct CodexTurnLedgerFile: Codable {
    var records: [String: CodexTurnLedgerRecord] = [:]
    var surfaceOwners: [String: String] = [:]
}

extension CMUXCLI {
    /// Builds one Codex invocation identity per hook. The inherited owner PID
    /// remains a claim and never supplies the nested decision alone.
    func codexHookInvocation(environment: [String: String]) -> CodexHookInvocation {
        let initial = CodexHookInvocation(environment: environment)
        let nested = nestedAgentSessionDetected(
            currentAgentPID: initial.observedPID,
            env: environment
        )
        return CodexHookInvocation(
            environment: environment,
            fallbackObservedPID: initial.observedPID,
            hasNestedAgentAncestor: nested
        )
    }

    func codexTurnLedger(environment: [String: String]) -> CodexTurnLedger {
        CodexTurnLedger(environment: environment)
    }
}
