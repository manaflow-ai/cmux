import CmuxAgentReplica
import Foundation

struct SessionRecordDraft: Hashable, Sendable {
    var id: AgentSessionID
    var kind: AgentKind
    var phase: SessionPhase
    var surfaceID: String?
    var cwd: String
    var title: String
    var workspaceName: String
    var lastActivityHint: Int
    var evidence: DetectionEvidence

    init(
        id: AgentSessionID,
        kind: AgentKind,
        phase: SessionPhase,
        surfaceID: String?,
        cwd: String,
        title: String,
        workspaceName: String,
        lastActivityHint: Int,
        evidence: DetectionEvidence
    ) {
        self.id = id
        self.kind = kind
        self.phase = phase
        self.surfaceID = surfaceID
        self.cwd = cwd
        self.title = title
        self.workspaceName = workspaceName
        self.lastActivityHint = lastActivityHint
        self.evidence = evidence
    }

    func snapshot(macDeviceID: MacDeviceID, version: EntityVersion) -> AgentSessionSnapshot {
        AgentSessionSnapshot(
            id: id,
            macDeviceID: macDeviceID,
            kind: kind,
            phase: phase,
            tier: evidence.tier,
            surfaceID: surfaceID,
            cwd: cwd,
            title: title,
            workspaceName: workspaceName,
            version: version,
            lastActivityHint: lastActivityHint
        )
    }
}
