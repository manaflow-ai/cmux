import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// On a fresh install Chief sends three short messages, a greeting, what it can do and a background
/// offer, each after its own quiet pause and typing dots, as Messages paces a person's replies (user,
/// 2026-10-30; "more spaced out, better animation timings", 2026-10-31). Reduce Motion shows them at
/// once; the dots never stay after a failure.
struct ChiefWelcomeTests {
    enum Step: Equatable {
        case wait(Duration)
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

        func waited(_ pause: Duration) { steps.append(.wait(pause)) }
    }

    static let at = Date(timeIntervalSince1970: 1_793_404_800.25)
    static let keys = [ChiefWelcome.helloClientID, ChiefWelcome.aboutClientID, ChiefWelcome.backgroundClientID]

    @Test func eachMessageArrivesAfterItsOwnQuietAndDots() async throws {
        let owner = Owner()
        try await ChiefWelcome(conversation: "conv", owner: owner, showsTyping: true)
            .play(now: { Self.at }, wait: { await owner.waited($0) })
        let beats = ChiefWelcome.beats
        #expect(beats.map(\.clientID) == Self.keys)
        let expected = beats.flatMap { beat -> [Step] in
            [.wait(beat.quiet), .typing(true), .wait(beat.typing), .imported([beat.clientID]), .typing(false)]
        }
        #expect(await owner.steps == expected)
    }

    @Test func thePacingStaysInMessagesRange() {
        let beats = ChiefWelcome.beats
        // The window settles before the first dots; every later message waits for the bubble above to land.
        #expect(beats[0].quiet == .milliseconds(600))
        #expect(beats.dropFirst().allSatisfy { $0.quiet >= .milliseconds(600) && $0.quiet <= .seconds(1) })
        // The greeting types the shortest; no message keeps the dots past 2 s.
        #expect(beats[0].typing == .milliseconds(1200))
        #expect(beats.allSatisfy { $0.typing >= .milliseconds(1200) && $0.typing <= .seconds(2) })
        #expect(beats[1].typing > beats[0].typing)
        #expect(ChiefWelcome.typingTime(for: String(repeating: "x", count: 1000)) == .seconds(2))
        #expect(ChiefWelcome.readingPause(after: "hi") == .milliseconds(600))
        let total = beats.reduce(Duration.zero) { $0 + $1.quiet + $1.typing }
        #expect(total <= .seconds(8))
    }

    @Test func theWelcomeIsChiefsOwnThreeMessagesWithFixedKeys() async throws {
        let owner = Owner()
        let welcome = ChiefWelcome(conversation: "conv", owner: owner, showsTyping: false)
        try await welcome.play(now: { Self.at }, wait: { _ in })
        let request = try #require(await owner.requests.first)
        #expect(request.conversation == "conv")
        #expect(request.messages.map(\.author) == ["agent_mux", "agent_mux", "agent_mux"])
        #expect(request.messages.allSatisfy { $0.createdAt == "2026-10-31T00:00:00.250Z" })
        #expect(request.messages[0].parts == [.object(["type": .string("text"), "text": .string(ChiefWelcome.helloText)])])
        #expect(ChiefWelcome.helloText.contains("cmux"))
        #expect(!ChiefWelcome.helloText.contains("\n"))
        #expect(!ChiefWelcome.aboutText.isEmpty)
        #expect(ChiefWelcome.backgroundText.contains("(cmux://settings/background)"))
    }

    @Test func reduceMotionSendsAtOnceWithoutDotsOrPauses() async throws {
        let owner = Owner()
        try await ChiefWelcome(conversation: "conv", owner: owner, showsTyping: false)
            .play(now: { Self.at }, wait: { await owner.waited($0) })
        #expect(await owner.steps == [.imported(Self.keys), .typing(false)])
    }

    @Test func aFailedImportTakesTheDotsAwayAndSendsNothingMore() async {
        let owner = Owner(fails: true)
        let welcome = ChiefWelcome(conversation: "conv", owner: owner, showsTyping: true)
        await #expect(throws: DaemonError.self) {
            try await welcome.play(now: { Self.at }, wait: { _ in })
        }
        #expect(await owner.steps == [.typing(true), .typing(false)])
    }
}
