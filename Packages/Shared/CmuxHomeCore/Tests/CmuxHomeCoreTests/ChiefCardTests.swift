@testable import CmuxHomeCore
import Foundation
import Testing

/// A Chief's `card` part (cmux issue 25830) from the hosted owners' JSON, its text fallback, and
/// which next-step chips a later person message chose.
struct ChiefCardTests {
    static func part(_ json: String) -> MessagePart {
        HomeWireMapping().part(HomeWireJSON.parse(json) ?? .null, messageID: "m1", index: 0)
    }

    @Test func aBrowserCardDecodesWithItsScreenshotAndTarget() {
        let part = Self.part("""
        {"type":"card","kind":"browser","surface":"browser","step":"Returning to LinkedIn Messaging","live":true,
         "target":"browser:right","url":"https://www.linkedin.com/messaging/",
         "image":{"hash":"\(String(repeating: "a", count: 64))","mime_type":"image/png","byte_count":123456,"width":1280,"height":800}}
        """)
        guard case .card(let card) = part else { Issue.record("not a card: \(part)"); return }
        #expect(card.kind == .browser)
        #expect(card.surface == .browser)
        #expect(card.step == "Returning to LinkedIn Messaging")
        #expect(card.live)
        #expect(card.openTarget == .browserRight)
        #expect(card.image?.width == 1280)
        #expect(part.blobHashes == [String(repeating: "a", count: 64)], "the screenshot is fetched by hash like a link preview's image")
        #expect(part.plainText == "Browser: Returning to LinkedIn Messaging")
    }

    @Test func aComputerCardNamesItsMachine() {
        let part = Self.part(#"{"type":"card","kind":"browser","surface":"computer","step":"Clicking Send","target":"machine:vm_1-a"}"#)
        guard case .card(let card) = part else { Issue.record("not a card: \(part)"); return }
        #expect(card.openTarget == .machine("vm_1-a"))
        #expect(!card.live, "live defaults to false")
        #expect(part.plainText == "Computer: Clicking Send")
    }

    @Test func targetsOutsideTheRuleOpenNothing() {
        #expect(ChiefCard.Target(wire: "browser:left") == nil)
        #expect(ChiefCard.Target(wire: "machine:") == nil)
        #expect(ChiefCard.Target(wire: "machine:a b") == nil)
        #expect(ChiefCard.Target(wire: "machine:\(String(repeating: "x", count: 129))") == nil)
        #expect(ChiefCard.Target(wire: "machine:vm_123")?.wire == "machine:vm_123")
    }

    @Test func aSignInCardDecodes() {
        let part = Self.part(#"{"type":"card","kind":"sign_in","site":"linkedin.com","url":"https://www.linkedin.com/login"}"#)
        guard case .card(let card) = part else { Issue.record("not a card: \(part)"); return }
        #expect(card.kind == .signIn)
        #expect(card.site == "linkedin.com")
        #expect(part.plainText == "Secure Store: sign in to linkedin.com")
    }

    @Test func nextStepsDecode() {
        let part = Self.part(#"{"type":"card","kind":"next_steps","choices":["Try sending the Kernel update again","Check the thread"]}"#)
        guard case .card(let card) = part else { Issue.record("not a card: \(part)"); return }
        #expect(card.choices == ["Try sending the Kernel update again", "Check the thread"])
        #expect(part.plainText == "→ Try sending the Kernel update again\n→ Check the thread")
    }

    @Test func aCardThisBuildCannotReadIsText() {
        #expect(Self.part(#"{"type":"card","kind":"poll","url":"https://example.com/p"}"#) == .text("https://example.com/p"))
        #expect(Self.part(#"{"type":"card","kind":"browser"}"#) == .text("card"), "a browser card needs its step")
        #expect(Self.part(#"{"type":"card","kind":"sign_in","site":"x.com"}"#) != .text("x.com"))
    }

    @Test func aPersonNeverSendsACard() {
        let wire = HomeWireMapping().wire(.card(.nextSteps(["a"])))
        #expect(wire["type"].string == "text")
    }

    @Test func theCardRoundTripsInTheOwnersShape() throws {
        let card = ChiefCard.browser(step: "Step", live: true, target: "browser:right",
                                     image: ChiefCard.Image(hash: "h", mimeType: "image/png", byteCount: 3, width: 2, height: 1))
        let data = try JSONEncoder().encode(card)
        let json = try #require(HomeWireJSON.parse(data))
        #expect(json["type"].string == "card")
        #expect(json["kind"].string == "browser")
        #expect(json["image"]["mime_type"].string == "image/png")
        #expect(try JSONDecoder().decode(ChiefCard.self, from: data) == card)
    }

    @Test func aChoiceIsChosenOnlyByExactlyItsText() {
        let choices = ["Try again", "Stop"]
        #expect(ChiefCard.chosen(choices, laterPersonTexts: ["try again", "Stop please"]) == [])
        #expect(ChiefCard.chosen(choices, laterPersonTexts: [" Try again\n"]) == ["Try again"])
    }
}
