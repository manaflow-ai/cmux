import CmuxAgentGUIProjection
import CmuxAgentSync

extension TranscriptStreamingTail {
    init(_ tail: AgentStreamingTail) {
        self.init(
            journalID: tail.journalID,
            afterSeq: tail.afterSeq,
            textTail: tail.textTail,
            revision: tail.revision
        )
    }
}
