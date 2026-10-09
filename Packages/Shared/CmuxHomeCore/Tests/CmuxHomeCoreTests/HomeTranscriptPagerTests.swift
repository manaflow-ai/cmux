import Testing
@testable import CmuxHomeCore

/// The transcript pager on its own: opens and closes pair up, only the last
/// close reports the conversation as gone, a reopen after it starts a new
/// epoch, and one older-page read runs per conversation.
@MainActor
@Suite struct HomeTranscriptPagerTests {
    let id = ConversationID("conv_aziz")

    @Test func opensAndClosesPairAndTheLastCloseEndsTheTranscript() {
        var pager = HomeTranscriptPager()
        #expect(!pager.close(id), "a close with no open does nothing")
        pager.open(id)
        pager.open(id)
        #expect(pager.viewers[id] == 2)
        #expect(!pager.close(id))
        #expect(pager.isShown(id))
        #expect(pager.close(id))
        #expect(!pager.isShown(id))
    }

    @Test func onlyAFirstOpenStartsANewEpoch() {
        var pager = HomeTranscriptPager()
        pager.open(id)
        let first = pager.epoch(id)
        pager.open(id)
        #expect(pager.epoch(id) == first)
        _ = pager.close(id)
        _ = pager.close(id)
        pager.open(id)
        #expect(pager.epoch(id) != first)
    }

    @Test func oneOlderPageReadRunsAtATime() {
        var pager = HomeTranscriptPager()
        #expect(pager.beginOlder(id))
        #expect(!pager.beginOlder(id))
        pager.endOlder(id)
        #expect(pager.beginOlder(id))
    }
}
