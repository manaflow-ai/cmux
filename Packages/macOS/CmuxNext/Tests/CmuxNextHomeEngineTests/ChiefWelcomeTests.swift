import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// On a fresh install Chief types for 1.5 s, then sends its first messages: a welcome and a
/// background offer, stored as Chief's own messages (user, 2026-10-30). Reduce Motion shows them
/// at once; the dots never stay after a failure or an abandoned welcome.
struct ChiefWelcomeTests {
    enum Step: Equatable {
        case typing(Bool)
        case imported([String])
    }

    actor Owner: ChiefWelcomeOwner {
        var steps: [Step] = []
        var requests: [ConversationImportRequest] = []
        let fails: Bool

        init(fails: Bool = false) { self.fails = fails }

        func showChiefTyping(_ on: Bool) { steps.append(.typing(on)) }

        func importWelcome(_ request: ConversationImportRequest) throws {
            if fails { throw DaemonError.notConnected }
            steps.append(.imported(request.messages.map(\.clientMsgID)))
            requests.append(request)
        }
    }

    static let at = Date(timeIntervalSince1970: 1_793_404_800.25)
    static let keys = [ChiefWelcome.welcomeClientID, ChiefWelcome.backgroundClientID]

    @Test func chiefTypesForOneAndAHalfSecondsThenSendsTheWelcome() async throws {
        let owner = Owner()
        let welcome = ChiefWelcome(conversation: "conv", owner: owner, showsTyping: true)
        #expect(await welcome.start() == .milliseconds(1500))
        #expect(await owner.steps == [.typing(true)])
        try await welcome.deliver(now: Self.at)
        #expect(await owner.steps == [.typing(true), .imported(Self.keys), .typing(false)])
    }

    @Test func theWelcomeIsChiefsOwnTwoMessagesWithFixedKeys() async throws {
        let owner = Owner()
        try await ChiefWelcome(conversation: "conv", owner: owner, showsTyping: true).deliver(now: Self.at)
        let request = try #require(await owner.requests.first)
        #expect(request.conversation == "conv")
        #expect(request.messages.map(\.author) == ["agent_mux", "agent_mux"])
        #expect(request.messages.map(\.createdAt) == ["2026-10-31T00:00:00.250Z", "2026-10-31T00:00:00.250Z"])
        #expect(request.messages[0].parts == [.object(["type": .string("text"), "text": .string(ChiefWelcome.welcomeText)])])
        #expect(ChiefWelcome.welcomeText.contains("cmux"))
        #expect(ChiefWelcome.backgroundText.contains("(cmux://settings/background)"))
    }

    @Test func reduceMotionSendsAtOnceWithoutDots() async throws {
        let owner = Owner()
        let welcome = ChiefWelcome(conversation: "conv", owner: owner, showsTyping: false)
        #expect(await welcome.start() == nil)
        try await welcome.deliver(now: Self.at)
        #expect(await owner.steps == [.imported(Self.keys), .typing(false)])
    }

    @Test func aFailedImportTakesTheDotsAwayAndThrows() async {
        let owner = Owner(fails: true)
        let welcome = ChiefWelcome(conversation: "conv", owner: owner, showsTyping: true)
        _ = await welcome.start()
        await #expect(throws: DaemonError.self) { try await welcome.deliver(now: Self.at) }
        #expect(await owner.steps == [.typing(true), .typing(false)])
    }

    @Test func anAbandonedWelcomeStoresNothingAndTakesTheDotsAway() async {
        let owner = Owner()
        let welcome = ChiefWelcome(conversation: "conv", owner: owner, showsTyping: true)
        _ = await welcome.start()
        await welcome.abandon()
        #expect(await owner.steps == [.typing(true), .typing(false)])
    }
}
