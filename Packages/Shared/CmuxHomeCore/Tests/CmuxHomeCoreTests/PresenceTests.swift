import Foundation
import Testing
@testable import CmuxHomeCore

/// Chat multiplayer in Home (Leo, 2026-10-26: "also chief chats we need multiplayer"): who has a
/// conversation open is the owner's presence, the whole set per frame, and ends with the
/// connection as typing does.
@MainActor @Suite struct PresenceTests {
    let conv = ConversationID("conv_a")
    let other = ConversationID("conv_b")
    let ana = ParticipantID("user_ana")
    let sam = ParticipantID("user_sam")

    @Test func eachFrameReplacesTheConversationsSetAndEmptyIsNobody() {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.handle(.connection(.online))
        store.handle(.presence(conv, viewing: [ana, sam]))
        store.handle(.presence(other, viewing: [sam]))
        #expect(store.viewing[conv] == [ana, sam])
        store.handle(.presence(conv, viewing: [sam]))
        #expect(store.viewing[conv] == [sam], "a frame is the whole set, not a change")
        store.handle(.presence(conv, viewing: []))
        #expect(store.viewing[conv] == nil, "nobody has no entry")
        #expect(store.viewing[other] == [sam], "another conversation keeps its own")
    }

    @Test func presenceEndsWithTheConnection() {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.handle(.connection(.online))
        store.handle(.presence(conv, viewing: [ana]))
        store.handle(.connection(.offline(since: Date(timeIntervalSince1970: 1))))
        #expect(store.viewing.isEmpty, "a frame lost while offline would leave faces nobody is behind")
        store.handle(.connection(.online))
        #expect(store.viewing.isEmpty, "they come back with the owner's next frame")
    }

    @Test func presenceIsNeverStoredInTheMirror() {
        var mirror = HomeMirror()
        let before = mirror
        #expect(mirror.apply(.presence(conv, viewing: [ana])) == .applied)
        #expect(mirror == before, "presence is live state, never cached")
    }
}
