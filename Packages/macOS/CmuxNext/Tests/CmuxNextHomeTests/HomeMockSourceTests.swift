@testable import CmuxNextHome
import Foundation
import Testing

struct HomeMockSourceTests {
    private func source() -> HomeMockSource {
        let me = HomeParticipant(id: HomeFixture.me, displayName: "Me", isMe: true)
        let agent = HomeParticipant(id: HomeFixture.agent, displayName: "Mux", isAgent: true)
        return HomeMockSource(conversationID: "conv", participants: [me, agent],
                              history: HomeMemoryHistory(HomeFixture.messages(1...100)))
    }

    @Test func pagesAreAscendingAndBounded() async throws {
        let source = source()
        let page = try await source.page(before: 51, limit: 20)
        #expect(page.compactMap(\.seq) == Array(31...50))
        #expect(try await source.page(before: 5, limit: 20).compactMap(\.seq) == [1, 2, 3, 4])
        #expect(source.newestSeq == 100 && source.oldestSeq == 1)
    }

    @Test func sendConfirmReceiveEmitChangesInOrder() async throws {
        let source = source()
        var changes: [String] = []
        let observation = source.observe { change in
            switch change {
            case .pendingAdded(let message): changes.append("pending \(message.rowKey)")
            case .pendingResolved(let id, let message): changes.append("resolved \(id) \(message.seq ?? -1)")
            case .appended(let messages): changes.append("appended \(messages.compactMap(\.seq))")
            case .typing(let ids): changes.append("typing \(ids)")
            default: break
            }
        }
        let id = source.addPending([.text("hello")])
        source.setTyping([HomeFixture.agent])
        let confirmed = try #require(source.confirm(clientMsgID: id))
        #expect(confirmed.rowKey == id)
        source.receive([.text("hi")], from: HomeFixture.agent)
        #expect(changes == ["pending \(id)", "typing [\"\(HomeFixture.agent)\"]", "resolved \(id) 101", "appended [102]"])
        #expect(try await source.page(before: 103, limit: 2).map(\.rowKey) == [id, "in_102"])
        observation.cancel()
        source.receive([.text("unobserved")], from: HomeFixture.agent)
        #expect(changes.count == 4)
    }
}
