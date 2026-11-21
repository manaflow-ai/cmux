import Foundation
import Testing
@testable import CmuxMobileAgentChat

// AgentSessionDirectory is iOS only: these run in the iOS simulator test pass.
#if os(iOS)
/// Audit 18 (state that grows forever): the directory kept a subscribed chat store for every grid
/// card, Feed row and chat made in a launch. Past ``AgentSessionDirectory/keptStores`` it lets go
/// of the least recently used store nobody else holds, and builds it again when asked.
@MainActor
@Suite struct AgentSessionDirectoryBoundTests {
    final class Weak {
        weak var value: AnyObject?
        init(_ value: AnyObject) { self.value = value }
    }

    /// A chat's source: its live stream is its subscription (alive while its store is).
    final class CountedSource: AgentSessionSource {
        let summary: AgentSessionSummary
        init(summary: AgentSessionSummary) { self.summary = summary }
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    static func summary(_ index: Int) -> AgentSessionSummary {
        AgentSessionSummary(id: "s\(index)", name: "chat \(index)", harness: "claude", agentName: "Claude", cwd: "~",
                            workspaceTitle: "w", macName: "Mac", branch: nil, status: .idle, macID: "mac-1")
    }

    /// A directory whose sources are counted in `sources`.
    static func directory(_ sources: Box) -> AgentSessionDirectory {
        let sessions = AgentSessionDirectory()
        sessions.makeSource = { summary in
            let source = CountedSource(summary: summary)
            sources.items.append(Weak(source))
            return source
        }
        return sessions
    }

    final class Box { var items: [Weak] = [] }

    static func live(_ items: [Weak]) -> Int { items.filter { $0.value != nil }.count }

    /// Detector: showing then hiding K > cap cards (each card holds its store while it shows, as
    /// its feed does) leaves at most `keptStores` stores, and subscriptions, alive. Before the
    /// bound every one of the K stayed subscribed for the launch.
    @Test func hidingManyCardsLeavesAtMostTheCapLive() async {
        let sources = Box()
        let sessions = Self.directory(sources)
        let cap = AgentSessionDirectory.keptStores
        var stores: [Weak] = []
        for index in 0..<(cap * 4) {
            var card: AgentChatStore? = sessions.store(for: Self.summary(index))
            stores.append(Weak(card!))
            card = nil
            _ = card
        }
        await Task.yield()
        #expect(Self.live(stores) <= cap)
        #expect(Self.live(sources.items) <= cap)
        // The most recent stay; the oldest went.
        #expect(stores.last?.value != nil)
        #expect(stores.first?.value == nil)
    }

    /// A card shown again gets its chat built again, for the same tab.
    @Test func aCardShownAgainGetsItsChatBack() {
        let sessions = Self.directory(Box())
        let cap = AgentSessionDirectory.keptStores
        let first = Weak(sessions.store(for: Self.summary(0)))
        for index in 1...(cap + 1) { _ = sessions.store(for: Self.summary(index)) }
        #expect(first.value == nil)
        #expect(sessions.existingStore(id: "s0", macID: "mac-1") == nil)
        let again = sessions.store(for: Self.summary(0))
        #expect(again.summary.id == "s0")
        #expect(sessions.existingStore(id: "s0", macID: "mac-1") === again)
    }

    /// A store something else still holds (a chat or card on screen) is never let go: a second
    /// store for its tab would split the chat's state.
    @Test func aStoreInUseStays() {
        let sessions = Self.directory(Box())
        let cap = AgentSessionDirectory.keptStores
        let shown = sessions.store(for: Self.summary(0))
        for index in 1...(cap * 3) { _ = sessions.store(for: Self.summary(index)) }
        #expect(sessions.store(for: Self.summary(0)) === shown)
    }

    /// A chat the person acted in keeps what only its store knows (a returned draft, sent
    /// attachments), so it stays loaded even when nothing shows it.
    @Test func aChatThePersonActedInStays() {
        let sessions = Self.directory(Box())
        let cap = AgentSessionDirectory.keptStores
        let acted = Weak(sessions.store(for: Self.summary(0)))
        (acted.value as? AgentChatStore)?.setModel("opus")
        for index in 1...(cap * 3) { _ = sessions.store(for: Self.summary(index)) }
        #expect(acted.value != nil)
        #expect(sessions.existingStore(id: "s0", macID: "mac-1") === acted.value)
    }

    /// Recently used stores stay ahead of older ones: asking for a store again keeps it.
    @Test func askingAgainKeepsAStore() {
        let sessions = Self.directory(Box())
        let cap = AgentSessionDirectory.keptStores
        let kept = Weak(sessions.store(for: Self.summary(0)))
        for index in 1...(cap * 3) {
            _ = sessions.store(for: Self.summary(index))
            _ = sessions.store(for: Self.summary(0))
        }
        #expect(kept.value != nil)
    }

    /// Stores let go are handed to `onRelease` first (notification previews save them).
    @Test func releasedStoresAreHandedOver() {
        let sessions = Self.directory(Box())
        let cap = AgentSessionDirectory.keptStores
        var released: [String] = []
        sessions.onRelease = { released += $0.map(\.summary.id) }
        for index in 0...cap { _ = sessions.store(for: Self.summary(index)) }
        #expect(released == ["s0"])
    }
}
#endif
