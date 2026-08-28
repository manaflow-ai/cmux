import Foundation

/// Durable, bounded owner and settlement state for Codex hooks.
///
/// This repository is intentionally separate from the general hook-session
/// snapshot: native child callbacks must commit a tiny record synchronously,
/// while loading a potentially large resume store would make the hook boundary
/// depend on unrelated session data. Every mutation is one locked transaction;
/// no delivery timing or transcript observation participates in settlement.
final class CodexTurnLedger {
    private enum Event {
        case sessionStart
        case promptSubmit(turnID: String?)
        case subagentStart(id: String?, turnID: String?)
        case subagentStop(id: String?, turnID: String?)
        case stop(turnID: String?)
        case sessionEnd
        case observation
    }

    private static let defaultFilename = "codex-turn-ledger.json"
    static let maximumRecords = 256
    static let maximumChildrenPerTurn = 128
    static let maximumTurnKeys = 64
    static let maximumTerminalChildrenPerTurn = 256
    static let maximumRememberedTurns = 128
    static let maximumIdentifierBytes = 512

    let path: String
    let fileManager: FileManager
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= maximumIdentifierBytes else { return nil }
        return value
    }

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        let rawPath = Self.normalized(environment[CodexHookInvocation.ledgerPathEnvironmentKey])
            ?? Self.normalized(environment["CMUX_AGENT_HOOK_STATE_DIR"]).map {
                URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true)
                    .appendingPathComponent(Self.defaultFilename, isDirectory: false)
                    .path
            }
            ?? URL(fileURLWithPath: "~/.cmuxterm", isDirectory: true)
                .appendingPathComponent(Self.defaultFilename, isDirectory: false)
                .path
        self.path = NSString(string: rawPath).expandingTildeInPath
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    deinit {}

    func sessionStart(
        sessionID: String,
        workspaceID: String?,
        surfaceID: String?,
        invocation: CodexHookInvocation
    ) throws -> CodexTurnLedgerDecision {
        try apply(
            .sessionStart,
            sessionID: sessionID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            invocation: invocation
        )
    }

    func promptSubmit(
        sessionID: String,
        turnID: String?,
        workspaceID: String?,
        surfaceID: String?,
        invocation: CodexHookInvocation
    ) throws -> CodexTurnLedgerDecision {
        try apply(
            .promptSubmit(turnID: turnID),
            sessionID: sessionID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            invocation: invocation
        )
    }

    func subagentStart(
        sessionID: String,
        agentID: String?,
        turnID: String?,
        workspaceID: String?,
        surfaceID: String?,
        invocation: CodexHookInvocation
    ) throws -> CodexTurnLedgerDecision {
        try apply(
            .subagentStart(id: agentID, turnID: turnID),
            sessionID: sessionID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            invocation: invocation
        )
    }

    func subagentStop(
        sessionID: String,
        agentID: String?,
        turnID: String?,
        workspaceID: String?,
        surfaceID: String?,
        invocation: CodexHookInvocation
    ) throws -> CodexTurnLedgerDecision {
        try apply(
            .subagentStop(id: agentID, turnID: turnID),
            sessionID: sessionID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            invocation: invocation
        )
    }

    func stop(
        sessionID: String,
        turnID: String?,
        workspaceID: String?,
        surfaceID: String?,
        invocation: CodexHookInvocation
    ) throws -> CodexTurnLedgerDecision {
        try apply(
            .stop(turnID: turnID),
            sessionID: sessionID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            invocation: invocation
        )
    }

    func sessionEnd(
        sessionID: String,
        workspaceID: String?,
        surfaceID: String?,
        invocation: CodexHookInvocation
    ) throws -> CodexTurnLedgerDecision {
        try apply(
            .sessionEnd,
            sessionID: sessionID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            invocation: invocation
        )
    }

    func observe(
        sessionID: String,
        workspaceID: String?,
        surfaceID: String?,
        invocation: CodexHookInvocation
    ) throws -> CodexTurnLedgerDecision {
        try apply(
            .observation,
            sessionID: sessionID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            invocation: invocation
        )
    }

    private func apply(
        _ event: Event,
        sessionID: String,
        workspaceID: String?,
        surfaceID: String?,
        invocation: CodexHookInvocation
    ) throws -> CodexTurnLedgerDecision {
        let normalizedSessionID = Self.normalized(sessionID) ?? ""
        guard !normalizedSessionID.isEmpty else { return .ignored }
        return try withLockedState { state in
            self.prune(&state)
            let normalizedWorkspaceID = Self.normalized(workspaceID) ?? ""
            let normalizedSurfaceID = Self.normalized(surfaceID) ?? ""
            let existing = state.records[normalizedSessionID]
            let ownerRecord = normalizedSurfaceID.isEmpty
                ? nil
                : state.surfaceOwners[normalizedSurfaceID].flatMap { state.records[$0] }
            let ownership = self.ownership(
                event: event,
                sessionID: normalizedSessionID,
                invocation: invocation,
                existing: existing,
                surfaceOwner: ownerRecord
            )
            if existing == nil, ownerRecord == nil, state.records.count >= Self.maximumRecords {
                self.prune(&state, retainingAtMost: Self.maximumRecords - 1)
            }
            if existing == nil, ownerRecord == nil, state.records.count >= Self.maximumRecords {
                return .ignored
            }

            if case .sessionStart = event, ownership == .foreground {
                let isSameOwner = existing.map { self.sameOwner($0.owner, invocation) } ?? false
                var record = existing ?? self.makeRecord(
                    workspaceID: normalizedWorkspaceID,
                    surfaceID: normalizedSurfaceID,
                    invocation: invocation
                )
                record.workspaceID = normalizedWorkspaceID.isEmpty ? record.workspaceID : normalizedWorkspaceID
                record.surfaceID = normalizedSurfaceID.isEmpty ? record.surfaceID : normalizedSurfaceID
                if !isSameOwner {
                    record = self.makeRecord(
                        workspaceID: record.workspaceID,
                        surfaceID: record.surfaceID,
                        invocation: invocation
                    )
                    if let oldOwner = ownerRecord,
                       let oldSessionID = state.surfaceOwners[normalizedSurfaceID],
                       oldSessionID != normalizedSessionID,
                       self.sameOwner(oldOwner.owner, invocation) == false {
                        state.records.removeValue(forKey: oldSessionID)
                    }
                }
                state.records[normalizedSessionID] = record
                if !normalizedSurfaceID.isEmpty {
                    state.surfaceOwners[normalizedSurfaceID] = normalizedSessionID
                }
                self.prune(&state)
                return self.decision(
                    ownership: .foreground,
                    settlement: .none,
                    activeChildCount: self.activeChildCount(record),
                    turnID: record.activeTurnID,
                    shouldNotify: false
                )
            }

            guard ownership == .foreground else {
                return self.decision(
                    ownership: ownership,
                    settlement: .none,
                    activeChildCount: existing.map(self.activeChildCount) ?? ownerRecord.map(self.activeChildCount) ?? 0,
                    turnID: existing?.activeTurnID,
                    shouldNotify: false
                )
            }

            var record = existing ?? ownerRecord ?? self.makeRecord(
                workspaceID: normalizedWorkspaceID,
                surfaceID: normalizedSurfaceID,
                invocation: invocation
            )
            if !normalizedWorkspaceID.isEmpty { record.workspaceID = normalizedWorkspaceID }
            if !normalizedSurfaceID.isEmpty { record.surfaceID = normalizedSurfaceID }
            if existing == nil {
                state.records[normalizedSessionID] = record
                if !normalizedSurfaceID.isEmpty { state.surfaceOwners[normalizedSurfaceID] = normalizedSessionID }
            }

            let decision: CodexTurnLedgerDecision
            switch event {
            case .promptSubmit(let turnID):
                let normalizedTurnID = Self.normalized(turnID)
                record.activeTurnID = normalizedTurnID
                let key = self.turnKey(normalizedTurnID)
                record.pendingTurns.removeValue(forKey: key)
                record.settledTurnIDs.removeAll { $0 == key }
                record.notifiedTurnIDs.removeAll { $0 == key }
                record.terminalChildrenByTurn.removeValue(forKey: key)
                decision = self.decision(
                    ownership: .foreground,
                    settlement: .none,
                    activeChildCount: self.activeChildCount(record),
                    turnID: record.activeTurnID,
                    shouldNotify: false
                )
            case .subagentStart(let id, let turnID):
                self.startChild(id: id, turnID: turnID, in: &record)
                decision = self.decision(
                    ownership: .foreground,
                    settlement: .none,
                    activeChildCount: self.activeChildCount(record),
                    turnID: Self.normalized(turnID) ?? record.activeTurnID,
                    shouldNotify: false
                )
            case .subagentStop(let id, let turnID):
                let key = self.turnKey(turnID ?? record.activeTurnID)
                let validChildID = Self.normalized(id) != nil
                self.stopChild(id: id, turnID: turnID, in: &record)
                if validChildID,
                   self.activeChildCount(for: key, in: record) == 0,
                   let pending = record.pendingTurns.removeValue(forKey: key) {
                    if !record.settledTurnIDs.contains(key) {
                        record.settledTurnIDs.append(key)
                    }
                    let shouldNotify = !record.notifiedTurnIDs.contains(key)
                    if shouldNotify {
                        record.notifiedTurnIDs.append(key)
                    }
                    decision = self.decision(
                        ownership: .foreground,
                        settlement: .settled,
                        activeChildCount: self.activeChildCount(record),
                        turnID: pending.turnID,
                        shouldNotify: shouldNotify
                    )
                } else {
                    decision = self.decision(
                        ownership: .foreground,
                        settlement: .none,
                        activeChildCount: self.activeChildCount(record),
                        turnID: Self.normalized(turnID) ?? record.activeTurnID,
                        shouldNotify: false
                    )
                }
            case .stop(let turnID):
                let key = self.turnKey(turnID ?? record.activeTurnID)
                let active = self.activeChildCount(record)
                if active > 0 {
                    record.pendingTurns[key] = CodexTurnLedgerPending(turnID: Self.normalized(turnID ?? record.activeTurnID))
                    decision = self.decision(
                        ownership: .foreground,
                        settlement: .pending,
                        activeChildCount: active,
                        turnID: Self.normalized(turnID ?? record.activeTurnID),
                        shouldNotify: false
                    )
                } else if record.settledTurnIDs.contains(key) {
                    let shouldNotify = !record.notifiedTurnIDs.contains(key)
                    if shouldNotify {
                        record.notifiedTurnIDs.append(key)
                    }
                    decision = self.decision(
                        ownership: .foreground,
                        settlement: shouldNotify ? .settled : .duplicate,
                        activeChildCount: 0,
                        turnID: Self.normalized(turnID ?? record.activeTurnID),
                        shouldNotify: shouldNotify
                    )
                } else {
                    record.pendingTurns.removeValue(forKey: key)
                    record.settledTurnIDs.append(key)
                    let shouldNotify = !record.notifiedTurnIDs.contains(key)
                    if shouldNotify { record.notifiedTurnIDs.append(key) }
                    decision = self.decision(
                        ownership: .foreground,
                        settlement: .settled,
                        activeChildCount: 0,
                        turnID: Self.normalized(turnID ?? record.activeTurnID),
                        shouldNotify: shouldNotify
                    )
                }
            case .sessionEnd:
                if let mappedSurface = Self.normalized(record.surfaceID),
                   state.surfaceOwners[mappedSurface] == normalizedSessionID {
                    state.surfaceOwners.removeValue(forKey: mappedSurface)
                }
                state.records.removeValue(forKey: normalizedSessionID)
                return self.decision(
                    ownership: .foreground,
                    settlement: .none,
                    activeChildCount: 0,
                    turnID: nil,
                    shouldNotify: false
                )
            case .observation, .sessionStart:
                decision = self.decision(
                    ownership: .foreground,
                    settlement: .none,
                    activeChildCount: self.activeChildCount(record),
                    turnID: record.activeTurnID,
                    shouldNotify: false
                )
            }

            record.updatedAt = Date.now.timeIntervalSince1970
            self.trim(&record)
            state.records[normalizedSessionID] = record
            if !record.surfaceID.isEmpty { state.surfaceOwners[record.surfaceID] = normalizedSessionID }
            self.prune(&state)
            return decision
        }
    }

    private func ownership(
        event: Event,
        sessionID _: String,
        invocation: CodexHookInvocation,
        existing: CodexTurnLedgerRecord?,
        surfaceOwner: CodexTurnLedgerRecord?
    ) -> CodexTurnLedgerOwnership {
        if let owner = existing ?? surfaceOwner {
            if invocation.parentToken != nil,
               invocation.parentToken == owner.owner.token,
               invocation.parentToken?.isEmpty == false {
                return .nested
            }
            if invocation.hasNestedAgentAncestor { return .nested }
            if sameOwner(owner.owner, invocation) {
                return .foreground
            }
            if existing != nil,
               let token = invocation.token,
               let ownerToken = owner.owner.token,
               token == ownerToken {
                if invocation.hasExplicitObservedPID,
                   owner.owner.pid != invocation.ownerPID {
                    return .nested
                }
                // A hook shell may sit between the foreground Codex and the
                // CLI, so its observed PID can differ while the session id and
                // invocation token remain the same. A second known agent (or an
                // explicit parent token) was handled above; this is the safe
                // same-session foreground case.
                return .foreground
            }
            if existing != nil,
               invocation.token == nil,
               owner.owner.token == nil {
                if invocation.hasExplicitObservedPID,
                   owner.owner.pid != invocation.ownerPID {
                    return .nested
                }
                return .foreground
            }
            if let token = invocation.token,
               let ownerToken = owner.owner.token,
               token == ownerToken {
                // A shared token with a different observed process is an
                // inherited outer environment, never a new foreground turn.
                return .nested
            }
            if case .sessionStart = event {
                // A fresh wrapper token is a legitimate top-level replacement;
                // nested wrapper launches carry parentToken and were handled
                // above. Legacy unwrapped launches are admitted only when the
                // prior process generation is demonstrably gone or older.
                if let incoming = invocation.ownerGeneration,
                   let previous = owner.owner.generation,
                   incoming > previous {
                    return .foreground
                }
                if owner.owner.pid != invocation.ownerPID {
                    // A new unwrapped top-level process has no inherited
                    // owner claim. A nested direct exec keeps the exact outer
                    // numeric claim and therefore does not enter this arm.
                    if invocation.ownerPID == nil
                        || owner.owner.pid.flatMap({ AgentPIDProcessIdentity(pid: pid_t($0)) }) == nil {
                        return .foreground
                    }
                }
                return invocation.token == nil ? .unknown : .foreground
            }
            // An event for an unknown session on an occupied surface is not
            // allowed to invent a new owner. This is the fail-closed boundary
            // that protects the foreground resume identity.
            return .unknown
        }
        // Legacy direct launches may omit SessionStart; preserve them unless
        // a tokenized child contradicts the claimed owner PID.
        if invocation.ownerPID != nil,
           invocation.observedPID != invocation.ownerPID {
            if case .sessionStart = event {
                return .foreground
            }
            return .unknown
        }
        return .foreground
    }

    private func sameOwner(_ owner: CodexTurnLedgerOwner, _ invocation: CodexHookInvocation) -> Bool {
        if let ownerGeneration = owner.generation,
           let observedGeneration = invocation.observedGeneration {
            return ownerGeneration == observedGeneration
        }
        if let ownerPID = owner.pid,
           let observedPID = invocation.observedPID {
            return ownerPID == observedPID
        }
        if let ownerToken = owner.token,
           let token = invocation.token {
            return ownerToken == token && invocation.observedPID == nil
        }
        return owner.pid == nil && invocation.ownerPID == nil
    }

    private func makeRecord(
        workspaceID: String,
        surfaceID: String,
        invocation: CodexHookInvocation
    ) -> CodexTurnLedgerRecord {
        CodexTurnLedgerRecord(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            owner: CodexTurnLedgerOwner(
                token: invocation.token,
                pid: invocation.ownerPID ?? invocation.observedPID,
                generation: invocation.ownerGeneration ?? invocation.observedGeneration
            ),
            activeTurnID: nil,
            activeChildrenByTurn: [:],
            unknownChildrenByTurn: [:],
            terminalChildrenByTurn: [:],
            pendingTurns: [:],
            settledTurnIDs: [],
            notifiedTurnIDs: [],
            updatedAt: Date.now.timeIntervalSince1970
        )
    }

    private func startChild(id: String?, turnID: String?, in record: inout CodexTurnLedgerRecord) {
        let key = turnKey(turnID ?? record.activeTurnID)
        guard record.activeChildrenByTurn[key] != nil || record.unknownChildrenByTurn[key] != nil || record.activeChildrenByTurn.count + record.unknownChildrenByTurn.count < Self.maximumTurnKeys else {
            incrementUnknownChildCount(key, in: &record)
            return
        }
        guard let id = Self.normalized(id), id.utf8.count <= Self.maximumIdentifierBytes else {
            incrementUnknownChildCount(key, in: &record)
            return
        }
        if record.terminalChildrenByTurn[key]?.contains(id) == true { return }
        var children = record.activeChildrenByTurn[key] ?? []
        if !children.contains(id) {
            if children.count >= Self.maximumChildrenPerTurn {
                incrementUnknownChildCount(key, in: &record)
            } else {
                children.append(id)
                record.activeChildrenByTurn[key] = children
            }
        }
    }
}
