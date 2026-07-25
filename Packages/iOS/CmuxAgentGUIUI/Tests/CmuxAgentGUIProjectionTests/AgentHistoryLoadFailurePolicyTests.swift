import CmuxAgentGUIProjection
import CmuxAgentReplica
@testable import CmuxAgentGUIUI
import Testing

@Suite
struct AgentHistoryLoadFailurePolicyTests {
    @Test
    func hidesHistoryBannerWhenTranscriptRowsRemainUsable() {
        let input = TranscriptProjectionInput(entries: [
            EntrySnapshot(
                journalID: JournalID(rawValue: "journal"),
                seq: EntrySeq(rawValue: 1),
                kind: .agentProse,
                content: EntryContent(
                    contentHash: 1,
                    payload: .agentProse(AgentProsePayload(markdown: "visible"))
                ),
                version: EntityVersion(rawValue: 1),
                timestampMilliseconds: 1
            )
        ], hasMoreBefore: true)

        #expect(!AgentHistoryLoadFailurePolicy.shouldShowBanner(failure: .older, input: input))
        #expect(!AgentHistoryLoadFailurePolicy.shouldShowBanner(failure: .head, input: input))
    }

    @Test
    func showsHistoryBannerWhenNoTranscriptRowsCanRender() {
        let input = TranscriptProjectionInput(entries: [], hasMoreBefore: true)

        #expect(AgentHistoryLoadFailurePolicy.shouldShowBanner(failure: .older, input: input))
    }

    @Test
    func noFailureNeverShowsHistoryBanner() {
        let input = TranscriptProjectionInput(entries: [], hasMoreBefore: true)

        #expect(!AgentHistoryLoadFailurePolicy.shouldShowBanner(failure: nil, input: input))
    }
}
