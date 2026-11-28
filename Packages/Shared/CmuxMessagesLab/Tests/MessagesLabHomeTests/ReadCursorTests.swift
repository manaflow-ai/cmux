import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// The open, visible conversation is read: the read cursor follows the
/// newest committed message on show and when the Chief's replies arrive
/// while the conversation is on screen (nxdog61: the Chief row showed 4
/// unread while its conversation was open).
@MainActor @Suite(.serialized) struct ReadCursorTests {
    let me = Fixture2.me, them = Fixture2.them

    private func readCursors(_ source: ScriptedSource) async -> [Seq] {
        await source.submitted.compactMap { if case let .setReadCursor(_, seq) = $0.op { return seq } else { return nil } }
    }

    @Test func theChiefsRepliesAreReadWhileTheConversationIsOnScreen() async throws {
        let source = ScriptedSource(me: Fixture2.people[0], summary: Fixture2.summary(lastSeq: 2),
                                    messages: [Fixture2.message(1, me, "hi"), Fixture2.message(2, them, "hello")])
        let store = HomeStore(source: source)
        store.start()
        await waitUntil { store.isOnline && store.me != nil }
        await store.open(Fixture2.id)
        let (p, c) = Fixture2.projection(store: store)
        c.host.layoutSubtreeIfNeeded()
        p.start()
        p.isVisibleToUser = true
        var cursors: [Seq] = []
        for _ in 0..<400 where cursors.isEmpty { try? await Task.sleep(for: .milliseconds(5)); cursors = await readCursors(source) }
        #expect(cursors.last == 2, "shown: read to the newest message, got \(cursors)")
        // Two Chief replies arrive while it is on screen.
        await source.publish(.message(Fixture2.message(3, them, "one"), rev: 11))
        await source.publish(.message(Fixture2.message(4, them, "two"), rev: 12))
        for _ in 0..<400 where cursors.last != 4 { try? await Task.sleep(for: .milliseconds(5)); cursors = await readCursors(source) }
        #expect(cursors.last == 4, "the replies that arrived while open are read, got \(cursors)")
        p.stop()
        store.stop()
    }
}
