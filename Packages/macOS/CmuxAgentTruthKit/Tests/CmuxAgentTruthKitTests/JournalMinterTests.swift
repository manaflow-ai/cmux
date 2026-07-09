import CmuxAgentReplica
@testable import CmuxAgentTruthKit
import Testing

@Suite
struct JournalMinterTests {
    @Test
    func journalIdentityDecisions() {
        var minter = JournalMinter()
        let first = JournalIdentity(path: "/tmp/example/rollout.jsonl", inodeLikeToken: "inode-1", headTruncated: false)
        let firstDecision = minter.decide(previous: nil, current: first, currentJournalID: nil)
        let firstID = id(from: firstDecision)

        #expect(minter.decide(previous: first, current: first, currentJournalID: firstID) == .same(firstID))

        let inodeChange = JournalIdentity(path: first.path, inodeLikeToken: "inode-2", headTruncated: false)
        let inodeID = id(from: minter.decide(previous: first, current: inodeChange, currentJournalID: firstID))
        #expect(inodeID != firstID)

        let truncated = JournalIdentity(path: first.path, inodeLikeToken: first.inodeLikeToken, headTruncated: true)
        let truncatedID = id(from: minter.decide(previous: first, current: truncated, currentJournalID: firstID))
        #expect(truncatedID != firstID)
        #expect(truncatedID != inodeID)
        #expect(minter.decide(previous: truncated, current: truncated, currentJournalID: truncatedID) == .same(truncatedID))

        let secondTruncation = JournalIdentity(path: first.path, inodeLikeToken: "inode-3", headTruncated: true)
        let secondTruncatedID = id(from: minter.decide(previous: truncated, current: secondTruncation, currentJournalID: truncatedID))
        #expect(secondTruncatedID != truncatedID)
        #expect(secondTruncatedID != firstID)

        let pathSwap = JournalIdentity(path: "/tmp/example/new.jsonl", inodeLikeToken: first.inodeLikeToken, headTruncated: false)
        let pathSwapID = id(from: minter.decide(previous: first, current: pathSwap, currentJournalID: firstID))
        #expect(pathSwapID != firstID)

        let backToAID = id(from: minter.decide(previous: pathSwap, current: first, currentJournalID: pathSwapID))
        #expect(backToAID != firstID)
        #expect(backToAID != pathSwapID)
    }

    private func id(from decision: JournalDecision) -> JournalID {
        switch decision {
        case .same(let id), .created(let id):
            id
        }
    }
}
