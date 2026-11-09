import AppKit
@testable import CmuxHomeCore
import CmuxHomeRender
import Foundation
import Testing
@testable import MessagesLabHome

/// A Chief turn that failed posts `(turn failed on claude: fetch failed)` to the conversation (every
/// bridge reads that text). Home draws it as an error card in plain words, not the raw line
/// (Lawrence 2026-11-07: "we need better error messages in the chat ui itself"): what happened,
/// and the raw words one click away.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct HomeTurnFailureCardTests {
    static let kind = "cmux.turnFailure"

    /// The shown message the Chief posted under `key`.
    func shown(_ key: IdempotencyKey, in rig: HomeChatRig) throws -> MessagesLabHome.Message {
        let item = try #require(rig.store.transcript(for: HomeChatRig.conversation).first { $0.key == key })
        let id = HomeMapping.id(item, aliases: rig.view.projection.aliases)
        return try #require(rig.view.controller.store?.state.conversation.messages.first { $0.id == id })
    }

    func texts(_ message: MessagesLabHome.Message) -> [String] {
        message.parts.compactMap { if case let .text(t, _) = $0 { t } else { nil } }
    }

    /// What the card says, as its provider reads it out (copy, accessibility).
    func card(_ message: MessagesLabHome.Message) -> String? {
        for part in message.parts {
            if case .custom(let custom) = part, custom.kind == Self.kind {
                return CustomRows.provider(Self.kind)?.plainText(custom)
            }
        }
        return nil
    }

    @Test(arguments: [
        ("(turn failed on claude: fetch failed)", "The Chief couldn't reach its model."),
        ("(turn failed: You've hit your weekly limit · resets Oct 25 at 9pm)", "The Chief reached its usage limit."),
        ("(turn failed on codex (fallback for claude): Internal error)", "The model service had a problem."),
        ("(turn failed: acp handshake: unexpected frame 0x1f)", "The Chief's reply failed."),
    ])
    func aFailedTurnIsAPlainWordsCardNotTheRawLine(text: String, title: String) async throws {
        let rig = try await HomeChatRig(history: 1)
        defer { rig.stop() }
        let key = IdempotencyKey("turn-failure-\(UUID().uuidString)")
        #expect(await rig.post(text, key: key))
        rig.frame()
        let message = try shown(key, in: rig)
        #expect(!texts(message).joined().contains("(turn failed"), "the raw line is not the bubble")
        let words = try #require(card(message))
        #expect(words.hasPrefix(title))
        #expect(words.contains(String(text.dropFirst().dropLast())), "the raw words stay with the card")
    }

    @Test func whatTheChiefSaidBeforeItFailedStaysItsBubble() async throws {
        let rig = try await HomeChatRig(history: 1)
        defer { rig.stop() }
        let key = IdempotencyKey("turn-failure-\(UUID().uuidString)")
        #expect(await rig.post("Let me check the build.\n\n(turn failed on claude: fetch failed)", key: key))
        rig.frame()
        let message = try shown(key, in: rig)
        #expect(texts(message) == ["Let me check the build."])
        #expect(card(message)?.hasPrefix("The Chief couldn't reach its model.") == true)
    }

    @Test func aPersonsMessageThatQuotesAFailureStaysText() async throws {
        let rig = try await HomeChatRig(history: 1)
        defer { rig.stop() }
        #expect(await rig.send("\(HomeChatRig.tag) why did it say (turn failed: fetch failed)") == nil)
        rig.frame()
        #expect(rig.bubbles().last?.contains("(turn failed: fetch failed)") == true)
    }
}
