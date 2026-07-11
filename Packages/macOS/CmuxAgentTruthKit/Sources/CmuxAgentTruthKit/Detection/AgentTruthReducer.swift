public import CmuxAgentReplica
import Foundation

/// Folds heterogeneous truth-channel observations into versioned session snapshots.
@MainActor
public final class AgentTruthReducer {
    private let macDeviceID: MacDeviceID
    private var records: [AgentSessionID: SessionRecord]

    /// The current session snapshots keyed by session id.
    public var snapshots: [AgentSessionID: AgentSessionSnapshot] {
        records.mapValues { $0.snapshot(macDeviceID: macDeviceID) }
    }

    /// The current detection evidence keyed by session id.
    public var evidence: [AgentSessionID: DetectionEvidence] {
        records.mapValues(\.draft.evidence)
    }

    /// Creates an agent truth reducer.
    /// - Parameter macDeviceID: The Mac device id to stamp onto snapshots.
    public init(macDeviceID: MacDeviceID) {
        self.macDeviceID = macDeviceID
        self.records = [:]
    }

    /// Folds one truth signal into the current session set.
    /// - Parameter signal: The channel signal to fold.
    /// - Returns: The versioned changes emitted by the fold.
    public func fold(_ signal: TruthChannelSignal) -> [AgentTruthChange] {
        switch signal {
        case .processObserved(let observation, let tick):
            return foldProcessObserved(observation, tick: tick)
        case .processGone(let pid, let startTick, let tick):
            return foldProcessGone(pid: pid, startTick: startTick, tick: tick)
        case .wrapperLaunched(let fact, let tick):
            return foldWrapperLaunched(fact, tick: tick)
        case .hookEvent(let fact, let tick):
            return foldHookEvent(fact, tick: tick)
        case .transcriptCorroboration(let sessionID, let fact, let tick):
            return foldTranscriptCorroboration(sessionID: sessionID, fact: fact, tick: tick)
        }
    }

    private func foldProcessObserved(_ observation: ProcessObservation, tick: Int) -> [AgentTruthChange] {
        let processIdentity = ProcessIdentity(pid: observation.pid, startTick: observation.startTick)
        let id = identityForProcessObservation(observation)
        var draft = records[id]?.draft ?? SessionRecordDraft(
            id: id,
            kind: observation.agentKindGuess,
            phase: .starting,
            surfaceID: observation.surfaceID,
            cwd: observation.cwd,
            title: observation.argvSummary,
            workspaceName: "",
            lastActivityHint: tick,
            evidence: DetectionEvidence()
        )
        draft.kind = preferredKind(existing: draft.kind, incoming: observation.agentKindGuess)
        draft.surfaceID = draft.surfaceID ?? observation.surfaceID
        draft.cwd = observation.cwd
        draft.title = observation.argvSummary
        draft.lastActivityHint = tick
        draft.evidence.hasProcessObservation = true
        draft.evidence.processIdentity = processIdentity
        draft.evidence.transcriptPath = observation.openTranscriptPath ?? draft.evidence.transcriptPath
        if draft.phase == .ended {
            draft.phase = .idle
        }
        return commit(draft)
    }

    private func foldProcessGone(pid: Int32, startTick: Int, tick: Int) -> [AgentTruthChange] {
        guard let id = records.first(where: { _, record in
            guard let identity = record.draft.evidence.processIdentity, identity.pid == pid else {
                return false
            }
            return identity.startTick == nil || identity.startTick == startTick
        })?.key else {
            return []
        }
        var draft = records[id]!.draft
        draft.phase = .ended
        draft.lastActivityHint = tick
        return commit(draft)
    }

    private func foldWrapperLaunched(_ fact: WrapperLaunchFact, tick: Int) -> [AgentTruthChange] {
        let preferredID = fact.sessionID ?? matchingID(surfaceID: fact.surfaceID, pid: fact.pid) ?? AgentSessionID(rawValue: "prov:\(fact.surfaceID):\(tick)")
        if let sessionID = fact.sessionID {
            if let changes = mergeIfNeeded(realID: sessionID, surfaceID: fact.surfaceID, pid: fact.pid, applying: { draft in
                applyWrapperLaunch(fact, tick: tick, to: &draft)
            }) {
                return changes
            }
        }
        var draft = records[preferredID]?.draft ?? SessionRecordDraft(
            id: preferredID,
            kind: fact.agentKind,
            phase: fact.launchArgvKind == .resume ? .idle : .starting,
            surfaceID: fact.surfaceID,
            cwd: fact.cwd,
            title: fact.agentKind.rawValue,
            workspaceName: "",
            lastActivityHint: tick,
            evidence: DetectionEvidence()
        )
        draft.id = preferredID
        applyWrapperLaunch(fact, tick: tick, to: &draft)
        return commit(draft)
    }

    private func foldHookEvent(_ fact: HookFact, tick: Int) -> [AgentTruthChange] {
        if let changes = mergeIfNeeded(realID: fact.sessionID, surfaceID: fact.surfaceID, pid: fact.pid, applying: { draft in
            applyHookEvent(fact, tick: tick, to: &draft)
        }) {
            return changes
        }
        var draft = records[fact.sessionID]?.draft ?? SessionRecordDraft(
            id: fact.sessionID,
            kind: .unknown("unknown"),
            phase: .unknown,
            surfaceID: fact.surfaceID,
            cwd: fact.cwd ?? "",
            title: "",
            workspaceName: "",
            lastActivityHint: tick,
            evidence: DetectionEvidence()
        )
        applyHookEvent(fact, tick: tick, to: &draft)
        return commit(draft)
    }

    private func foldTranscriptCorroboration(
        sessionID: AgentSessionID,
        fact: TranscriptCorroborationFact,
        tick: Int
    ) -> [AgentTruthChange] {
        guard var draft = records[sessionID]?.draft else {
            return []
        }
        draft.evidence.hasTranscriptCorroboration = true
        draft.lastActivityHint = tick
        switch fact {
        case .assistantTurnCompleted:
            if draft.phase == .working {
                draft.phase = .idle
            }
        case .userMessageAppended:
            draft.phase = .working
        }
        return commit(draft)
    }

    private func mergeIfNeeded(
        realID: AgentSessionID,
        surfaceID: String?,
        pid: Int32?,
        applying refine: (inout SessionRecordDraft) -> Void
    ) -> [AgentTruthChange]? {
        guard let surfaceID, let pid else {
            return nil
        }
        guard let existingID = matchingID(surfaceID: surfaceID, pid: pid), existingID != realID else {
            return nil
        }
        guard let existing = records.removeValue(forKey: existingID) else {
            return nil
        }
        let realRecord = records[realID]
        var merged = realRecord?.draft ?? existing.draft
        merged.id = realID
        merged.kind = preferredKind(existing: merged.kind, incoming: existing.draft.kind)
        merged.phase = existing.draft.phase == .unknown ? merged.phase : existing.draft.phase
        merged.surfaceID = merged.surfaceID ?? existing.draft.surfaceID
        merged.cwd = merged.cwd.isEmpty ? existing.draft.cwd : merged.cwd
        merged.title = merged.title.isEmpty ? existing.draft.title : merged.title
        merged.workspaceName = merged.workspaceName.isEmpty ? existing.draft.workspaceName : merged.workspaceName
        merged.lastActivityHint = max(merged.lastActivityHint, existing.draft.lastActivityHint)
        merged.evidence = mergeEvidence(merged.evidence, existing.draft.evidence)
        refine(&merged)
        return [.sessionRemoved(existingID)] + commit(merged, floorVersion: max(realRecord?.version.rawValue ?? 0, existing.version.rawValue))
    }

    private func commit(_ draft: SessionRecordDraft, floorVersion: UInt64 = 0) -> [AgentTruthChange] {
        if let existing = records[draft.id], existing.draft == draft {
            return []
        }
        let nextVersion = EntityVersion(rawValue: max(records[draft.id]?.version.rawValue ?? 0, floorVersion) + 1)
        records[draft.id] = SessionRecord(draft: draft, version: nextVersion)
        return [.sessionUpserted(draft.snapshot(macDeviceID: macDeviceID, version: nextVersion))]
    }

    private func identityForProcessObservation(_ observation: ProcessObservation) -> AgentSessionID {
        if let existing = matchingID(surfaceID: observation.surfaceID, pid: observation.pid) {
            return existing
        }
        if let transcriptPath = observation.openTranscriptPath {
            return AgentSessionID(rawValue: "transcript:\(stableHash(transcriptPath))")
        }
        if let surfaceID = observation.surfaceID {
            return AgentSessionID(rawValue: "prov:\(surfaceID):\(observation.startTick)")
        }
        return AgentSessionID(rawValue: "process:\(observation.pid):\(observation.startTick)")
    }

    private func matchingID(surfaceID: String?, pid: Int32?) -> AgentSessionID? {
        records.first { _, record in
            guard let surfaceID, let pid else {
                return false
            }
            return record.draft.surfaceID == surfaceID && record.draft.evidence.processIdentity?.pid == pid
        }?.key
    }

    private func preferredKind(existing: AgentKind, incoming: AgentKind) -> AgentKind {
        switch incoming {
        case .unknown:
            return existing
        default:
            if case .unknown = existing {
                return incoming
            }
            return existing == incoming ? existing : incoming
        }
    }

    private func applyWrapperLaunch(_ fact: WrapperLaunchFact, tick: Int, to draft: inout SessionRecordDraft) {
        draft.kind = preferredKind(existing: draft.kind, incoming: fact.agentKind)
        draft.surfaceID = fact.surfaceID
        draft.cwd = fact.cwd
        draft.title = draft.title.isEmpty ? fact.agentKind.rawValue : draft.title
        draft.lastActivityHint = tick
        if draft.phase == .ended, fact.launchArgvKind == .resume {
            draft.phase = .idle
        }
        draft.evidence.hasWrapperLaunch = true
        bindPid(fact.pid, to: &draft)
        if fact.socketWasDown {
            draft.evidence.reasons.insert(.launchedWhileSocketDown)
        }
        applyCapabilityFacts(
            hooksUnavailableSafeMode: fact.hooksUnavailableSafeMode,
            cliVersion: fact.cliVersion,
            minimumCLIVersion: fact.minimumCLIVersion,
            to: &draft
        )
    }

    private func applyHookEvent(_ fact: HookFact, tick: Int, to draft: inout SessionRecordDraft) {
        draft.id = fact.sessionID
        draft.surfaceID = draft.surfaceID ?? fact.surfaceID
        draft.cwd = fact.cwd ?? draft.cwd
        if fact.eventName != .subagentStop {
            draft.lastActivityHint = tick
        }
        draft.evidence.hasHookEvents = true
        draft.evidence.transcriptPath = fact.transcriptPath ?? draft.evidence.transcriptPath
        if let pid = fact.pid {
            bindPid(pid, to: &draft)
        }
        applyCapabilityFacts(
            hooksUnavailableSafeMode: fact.hooksUnavailableSafeMode,
            cliVersion: fact.cliVersion,
            minimumCLIVersion: fact.minimumCLIVersion,
            to: &draft
        )
        switch fact.eventName {
        case .sessionStart:
            draft.phase = .idle
        case .userPromptSubmit, .preToolUse, .postToolUse:
            draft.phase = .working
        case .permissionRequest:
            draft.phase = .needsInput
        case .notification:
            if fact.notificationRequiresInput {
                draft.phase = .needsInput
            }
        case .stop:
            draft.phase = .idle
        case .subagentStop:
            break
        case .sessionEnd:
            draft.phase = .ended
        case .unknown:
            if draft.phase == .unknown {
                draft.phase = .unknown
            }
        }
    }

    private func bindPid(_ pid: Int32, to draft: inout SessionRecordDraft) {
        if let identity = draft.evidence.processIdentity, identity.pid != pid {
            draft.evidence.reasons.insert(.evidenceConflict)
        } else if draft.evidence.processIdentity == nil {
            draft.evidence.processIdentity = ProcessIdentity(pid: pid, startTick: nil)
        }
    }

    private func applyCapabilityFacts(
        hooksUnavailableSafeMode: Bool,
        cliVersion: String?,
        minimumCLIVersion: String?,
        to draft: inout SessionRecordDraft
    ) {
        if hooksUnavailableSafeMode {
            draft.evidence.reasons.insert(.hooksUnavailableSafeMode)
        }
        if let cliVersion, let minimumCLIVersion, version(cliVersion, isBelow: minimumCLIVersion) {
            draft.evidence.reasons.insert(.cliVersionBelowMinimum(found: cliVersion, minimum: minimumCLIVersion))
        }
    }

    private func version(_ found: String, isBelow minimum: String) -> Bool {
        let foundParts = found.split(separator: ".").map { Int($0) ?? 0 }
        let minimumParts = minimum.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(foundParts.count, minimumParts.count)
        for index in 0 ..< count {
            let foundPart = index < foundParts.count ? foundParts[index] : 0
            let minimumPart = index < minimumParts.count ? minimumParts[index] : 0
            if foundPart != minimumPart {
                return foundPart < minimumPart
            }
        }
        return false
    }

    private func mergeEvidence(_ lhs: DetectionEvidence, _ rhs: DetectionEvidence) -> DetectionEvidence {
        var merged = lhs
        merged.hasProcessObservation = lhs.hasProcessObservation || rhs.hasProcessObservation
        merged.hasWrapperLaunch = lhs.hasWrapperLaunch || rhs.hasWrapperLaunch
        merged.hasHookEvents = lhs.hasHookEvents || rhs.hasHookEvents
        merged.hasTranscriptCorroboration = lhs.hasTranscriptCorroboration || rhs.hasTranscriptCorroboration
        merged.processIdentity = lhs.processIdentity ?? rhs.processIdentity
        merged.transcriptPath = lhs.transcriptPath ?? rhs.transcriptPath
        merged.reasons.formUnion(rhs.reasons)
        return merged
    }

    private func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
