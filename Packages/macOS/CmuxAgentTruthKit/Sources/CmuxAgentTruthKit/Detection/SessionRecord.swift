import CmuxAgentReplica
import Foundation

struct SessionRecord: Hashable, Sendable {
    var draft: SessionRecordDraft
    var version: EntityVersion

    init(draft: SessionRecordDraft, version: EntityVersion) {
        self.draft = draft
        self.version = version
    }

    func snapshot(macDeviceID: MacDeviceID) -> AgentSessionSnapshot {
        draft.snapshot(macDeviceID: macDeviceID, version: version)
    }
}
