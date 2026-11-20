import Foundation
import Testing
@testable import CmuxMobileNotifications

/// The long look's rows keep their ids as the history slides (a newer message in, the oldest
/// out), so only the new row draws. Position ids gave each kept message its neighbour's id.
@Suite struct PushHistoryRowIDTests {
    typealias Message = PushSnapshot.Message

    func conversation(_ count: Int) -> [Message] {
        (0..<count).map { Message(role: $0.isMultiple(of: 2) ? .user : .agent, text: "message \($0)") }
    }

    func id(of message: Message, in messages: [Message]) -> String? {
        zip(PushHistory.rowIDs(messages), messages).first { $0.1 == message }?.0
    }

    @Test func aNewerMessageKeepsTheKeptRowsIDs() {
        let all = conversation(PushHistory.limit + 1)
        let before = Array(all.prefix(PushHistory.limit))
        let after = Array(all.suffix(PushHistory.limit))
        for kept in all.dropFirst().dropLast() {
            #expect(id(of: kept, in: before) == id(of: kept, in: after), "\(kept.text) changed id")
        }
        let left = Set(PushHistory.rowIDs(before)).subtracting(PushHistory.rowIDs(after))
        let arrived = Set(PushHistory.rowIDs(after)).subtracting(PushHistory.rowIDs(before))
        #expect(left.count == 1 && arrived.count == 1, "one message in and one out changed \(arrived.count) row ids")
    }

    @Test func repeatedMessagesHaveTheirOwnIDs() {
        let messages = [Message(role: .agent, text: "Done."), Message(role: .user, text: "Again"), Message(role: .agent, text: "Done.")]
        let ids = PushHistory.rowIDs(messages)
        #expect(Set(ids).count == messages.count)
    }
}
