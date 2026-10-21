import Foundation
import Testing
@testable import CmuxHomeCore

/// Typing dots never outlive the connection that reported them (Lawrence
/// 2026-10-19: dots still showed under a finished Chief reply). Typing is the
/// owner's ephemeral state: a typing-off sent while this client was not
/// connected never arrives, so going offline drops what the client kept. A
/// running Chief turn still shows its dots from its live run.
@MainActor @Suite struct TypingLifetimeTests {
    let chief = ParticipantID("agent_chief")
    let conv = ConversationID("conv_a")

    @Test func typingEndsWhenTheConnectionDrops() {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.handle(.connection(.online))
        store.handle(.typing(conv, chief, on: true))
        #expect(store.typing[conv] == [chief])

        store.handle(.connection(.offline(since: Date(timeIntervalSince1970: 0))))
        #expect(store.typing[conv] == nil)

        // Back online: nothing comes back until the owner says so again.
        store.handle(.connection(.online))
        #expect(store.typing[conv] == nil)
        store.handle(.typing(conv, chief, on: true))
        #expect(store.typing[conv] == [chief])
    }

    @Test func typingEndsWhenTheClientReconnects() {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.handle(.connection(.online))
        store.handle(.typing(conv, chief, on: true))
        store.handle(.connection(.connecting))
        #expect(store.typing.isEmpty)
    }
}
