import Foundation
import Testing
@testable import CmuxConversationCore

/// A live change (an arrival, a tapback, a receipt, typing) touches the end
/// of a long transcript; the store says how much of the front is untouched,
/// so the transcript rebuilds only the rows after it.
@MainActor
@Suite struct ConversationTranscriptJournalTests {
    func loadedStore(total: Int = 40) async throws -> (ConversationStore, ScriptedBackend) {
        let backend = ScriptedBackend(total: total)
        let store = ConversationStore(backend: backend, pageSize: 30, clock: ImmediateClock())
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        return (store, backend)
    }

    @Test func anArrivalLeavesEveryEarlierMessageUnchanged() async throws {
        let (store, backend) = try await loadedStore()
        let count = store.messages.count
        let revision = store.transcriptRevision
        store.apply(.message(backend.makeMessage(seq: 41, sender: "lc"), eventSeq: 500))
        #expect(store.messages.count == count + 1)
        #expect(store.transcriptRevision != revision)
        #expect(store.unchangedMessagePrefix(since: revision) == count)
    }

    @Test func aTapbackOnAnOlderMessageChangesItAndNothingBefore() async throws {
        let (store, _) = try await loadedStore()
        let revision = store.transcriptRevision
        var target = store.messages[7]
        target.reactions = [ConversationReactionMark(participantID: "lc", reaction: .heart)]
        store.apply(.message(target, eventSeq: 500))
        #expect(store.messages[7].reactions.count == 1)
        #expect(store.unchangedMessagePrefix(since: revision) == 7)
        // Several changes since: the lowest one counts.
        var later = store.messages[20]
        later.text = "edited"
        store.apply(.message(later, eventSeq: 501))
        #expect(store.unchangedMessagePrefix(since: revision) == 7)
    }

    @Test func nothingChangedSinceTheRevisionKeepsEveryMessage() async throws {
        let (store, _) = try await loadedStore()
        let revision = store.transcriptRevision
        store.apply(.typing(participantID: "lc", isTyping: true))
        #expect(store.unchangedMessagePrefix(since: revision) == store.messages.count)
    }

    @Test func aRevisionOlderThanTheJournalIsUnknown() async throws {
        let (store, backend) = try await loadedStore()
        let revision = store.transcriptRevision
        for seq in 41...300 {
            store.apply(.message(backend.makeMessage(seq: seq, sender: "lc"), eventSeq: 500 + seq))
        }
        #expect(store.unchangedMessagePrefix(since: revision) == 0)
    }

    @Test func anOlderPageChangesEverything() async throws {
        let (store, _) = try await loadedStore()
        let revision = store.transcriptRevision
        store.loadOlder()
        try await waitUntil { store.messages.count == 40 }
        #expect(store.unchangedMessagePrefix(since: revision) == 0)
    }

    @Test func translationChangesEveryRow() async throws {
        let (store, _) = try await loadedStore()
        let revision = store.transcriptRevision
        store.translationsDidChange()
        #expect(store.unchangedMessagePrefix(since: revision) == 0)
    }
}
