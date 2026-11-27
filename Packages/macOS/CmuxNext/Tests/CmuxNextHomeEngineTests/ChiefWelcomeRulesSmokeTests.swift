import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// The welcome's rules are the Rust `welcome.*` ops (cmux-home-rules, tested there). This smoke test
/// crosses the FFI once each way: the script's beats, the played steps and the import request.
struct ChiefWelcomeRulesSmokeTests {
    enum Step: Equatable {
        case wait(Duration)
        case typing(Bool)
        case imported([String])
    }

    actor Owner: ChiefWelcomeOwner {
        var steps: [Step] = []
        var requests: [ConversationImportRequest] = []

        func showChiefTyping(_ on: Bool) { steps.append(.typing(on)) }

        func importWelcome(_ request: ConversationImportRequest) {
            steps.append(.imported(request.messages.map(\.clientMsgID)))
            requests.append(request)
        }

        func waited(_ pause: Duration) { steps.append(.wait(pause)) }
    }

    @Test func theWelcomePlaysThroughTheRustRules() async throws {
        let owner = Owner()
        let at = Date(timeIntervalSince1970: 1_793_404_800.25)
        try await ChiefWelcome(conversation: "conv", owner: owner, showsTyping: true, text: "About.")
            .play(now: { at }, pause: { await owner.waited($0) })
        let beats = ChiefWelcome.beats(about: "About.")
        #expect(beats.count == 3)
        #expect(beats[1].text == "About.")
        let expected = beats.flatMap { beat -> [Step] in
            [.wait(beat.quiet), .typing(true), .wait(beat.typing), .imported([beat.clientID]), .typing(false)]
        }
        #expect(await owner.steps == expected)
        let request = try #require(await owner.requests.first)
        #expect(request.conversation == "conv")
        #expect(request.messages.first?.createdAt == "2026-10-31T00:00:00.250Z")
        #expect(!ChiefWelcome.text(shortcuts: []).isEmpty)
    }
}
