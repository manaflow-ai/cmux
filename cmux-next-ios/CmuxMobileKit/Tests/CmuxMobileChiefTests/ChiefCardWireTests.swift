import CmuxConversationCore
import Foundation
import Testing
@testable import CmuxMobileChief

/// `card` parts (https://github.com/manaflow-ai/cmux/issues/25830) as the
/// conversation model's cards.
@Suite struct ChiefCardWireTests {
    let wire = ChiefWire(identity: .standard)
    let chief = ChiefIdentity.standard.chiefID

    func object(_ parts: [[String: Any]], retracted: Bool = false) -> [String: Any] {
        var object: [String: Any] = [
            "id": "m1", "seq": 4, "author": chief, "parts": parts, "created_at": "2026-10-26T18:34:00.000Z",
        ]
        if retracted { object["retracted_at"] = "2026-10-26T18:35:00.000Z" }
        return object
    }

    @Test func browserCardDecodesWithItsScreenshotBytes() throws {
        let hash = String(repeating: "ab", count: 32)
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let part: [String: Any] = [
            "type": "card", "kind": "browser", "surface": "browser", "step": "Returning to LinkedIn Messaging",
            "live": true, "target": "browser:right", "url": "https://www.linkedin.com/messaging/",
            "image": ["hash": hash, "mime_type": "image/png", "byte_count": 4, "width": 1280, "height": 800],
        ]
        let message = try #require(wire.message(object([part]), peerReadSeq: 0, bytes: [hash: png]))
        let card = try #require(message.browserCard)
        #expect(card.surface == .browser)
        #expect(card.step == "Returning to LinkedIn Messaging")
        #expect(card.live)
        #expect(card.target == .browserRight)
        #expect(card.url?.absoluteString == "https://www.linkedin.com/messaging/")
        #expect(card.image?.id == "att:\(hash)")
        #expect(card.image?.kind == .image)
        #expect(card.image?.width == 1280 && card.image?.height == 800)
        #expect(card.image?.localData == png)
        // The card is not text, and its screenshot is not one of the message's attachments.
        #expect(message.text.isEmpty)
        #expect(message.attachments.isEmpty)
        #expect(ChiefWire.byteHash(part) == hash)
    }

    @Test func computerCardForACloudMachine() throws {
        let part: [String: Any] = ["type": "card", "kind": "browser", "surface": "computer", "step": "Clicking Save",
                                   "target": "machine:vm_123-a"]
        let card = try #require(wire.message(object([part]), peerReadSeq: 0)?.browserCard)
        #expect(card.surface == .computer)
        #expect(!card.live)
        #expect(card.target == .machine("vm_123-a"))
        #expect(card.image == nil)
        #expect(card.fallbackText == "Computer: Clicking Save")
    }

    @Test func signInAndNextStepsRideAfterTheReplyText() throws {
        let parts: [[String: Any]] = [
            ["type": "text", "text": "The reply is paused on LinkedIn sign-in."],
            ["type": "card", "kind": "next_steps", "choices": ["Try sending the Kernel update again"]],
            ["type": "card", "kind": "sign_in", "site": "linkedin.com", "url": "https://www.linkedin.com/login"],
        ]
        let message = try #require(wire.message(object(parts), peerReadSeq: 0))
        #expect(message.text == "The reply is paused on LinkedIn sign-in.")
        #expect(message.nextSteps?.choices == ["Try sending the Kernel update again"])
        #expect(message.signInCard?.site == "linkedin.com")
        #expect(message.signInCard?.url?.absoluteString == "https://www.linkedin.com/login")
        #expect(message.cards.count == 2)
    }

    @Test func unknownOrMalformedCardsAreSkipped() throws {
        let parts: [[String: Any]] = [
            ["type": "card", "kind": "weather", "city": "Tokyo"],
            ["type": "card", "kind": "browser", "step": "   "],
            ["type": "card", "kind": "sign_in", "site": "LinkedIn"],
            ["type": "card", "kind": "next_steps", "choices": [String]()],
            ["type": "card", "kind": "browser", "step": "Open", "target": "machine:../etc", "url": "javascript:alert(1)"],
        ]
        let message = try #require(wire.message(object(parts), peerReadSeq: 0))
        #expect(message.cards.count == 1)
        let card = try #require(message.browserCard)
        // A bad target means no button; a non-web URL is dropped.
        #expect(card.target == nil)
        #expect(card.url == nil)
    }

    @Test func aRetractedMessageHasNoCards() throws {
        let part: [String: Any] = ["type": "card", "kind": "sign_in", "site": "linkedin.com"]
        let message = try #require(wire.message(object([part], retracted: true), peerReadSeq: 0))
        #expect(message.cards.isEmpty)
    }

    @Test func theMockPostsAllThreeCards() async throws {
        let mock = ChiefMockBackend(sleep: { _ in })
        let before = try await mock.history(beforeSeq: nil, limit: 100).messages.count
        await mock.postCardsDemo()
        let messages = try await mock.history(beforeSeq: nil, limit: 100).messages
        #expect(messages.count == before + 3)
        let browser = try #require(messages.compactMap(\.browserCard).first)
        // The live card was edited in place to its next step, with a new screenshot.
        #expect(browser.step == "Returning to LinkedIn Messaging")
        #expect(!browser.live)
        #expect(browser.image?.id == "att:mock-screenshot-2")
        #expect(browser.image?.localData?.isEmpty == false)
        #expect(messages.contains { $0.nextSteps?.choices == ["Try sending the Kernel update again"] })
        #expect(messages.contains { $0.signInCard?.site == "linkedin.com" })
    }
}
