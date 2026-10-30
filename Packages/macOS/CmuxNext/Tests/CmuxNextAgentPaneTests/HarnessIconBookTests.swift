import CmuxNextCompat
import CmuxNextDaemon
import Observation
import Testing
@testable import CmuxNextAgentPane

/// User 12922: the book keeps the icons of the last harness list, and a list with the same icons
/// is no change (the tab strip and sidebar do not map again for it).
@MainActor
struct HarnessIconBookTests {
    @Test func aReplysIconsReplaceTheBooksOnlyWhenTheyChange() {
        let book = HarnessIconBook(environment: { nil })
        #expect(book.icons == .none)
        let reply: [String: Any] = ["harnesses": [
            "fox": ["iconSpec": ["kind": "emoji", "text": "🦊", "source": "profile"]],
            "bad": ["iconSpec": ["kind": "image", "mime": "text/html", "data": "PA==", "source": "profile"]],
            "plain": ["kind": "acp"],
        ]]
        book.apply(harnessesReply: reply)
        #expect(book.icons.specs == ["fox": .emoji("🦊", isOwn: true)])
        let changes = Atomic<Int>(0)
        withObservationTracking { _ = book.icons } onChange: { changes.wrappingAdd(1, ordering: .relaxed) }
        book.apply(harnessesReply: reply)
        #expect(changes.load(ordering: .relaxed) == 0)
        book.apply(harnessesReply: ["harnesses": [:]])
        #expect(changes.load(ordering: .relaxed) == 1)
        #expect(book.icons == .none)
    }
}
