import CmuxHomeCore
import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// A Chief's `card` part (cmux issue 25830) from the local owner (CmuxNextDaemon's `ConversationPart`,
/// where a part type the daemon client does not model arrives as `.unknown`) as Home's `.card`, and the
/// Chief Secure Store's host rule (pure, no keychain).
struct ChiefCardMappingTests {
    static func part(_ json: String) throws -> MessagePart {
        let wire = try JSONDecoder().decode(ConversationPart.self, from: Data(json.utf8))
        return HomeCoreMapping.part(wire, messageID: "msg_1", index: 0)
    }

    @Test func eachKindMapsToACard() throws {
        let browser = try Self.part("""
        {"type":"card","kind":"browser","surface":"computer","step":"Clicking Send","live":false,"target":"machine:vm_9",
         "image":{"hash":"\(String(repeating: "b", count: 64))","mime_type":"image/jpeg","byte_count":10,"width":4,"height":3}}
        """)
        let signIn = try Self.part(#"{"type":"card","kind":"sign_in","site":"linkedin.com"}"#)
        let steps = try Self.part(#"{"type":"card","kind":"next_steps","choices":["One","Two"]}"#)
        #expect(browser == .card(.browser(surface: .computer, step: "Clicking Send", target: "machine:vm_9",
                                          image: ChiefCard.Image(hash: String(repeating: "b", count: 64), mimeType: "image/jpeg",
                                                                 byteCount: 10, width: 4, height: 3))))
        #expect(signIn == .card(.signIn(site: "linkedin.com")))
        #expect(steps == .card(.nextSteps(["One", "Two"])))
    }

    @Test func aCardOfAnUnknownKindIsItsText() throws {
        #expect(try Self.part(#"{"type":"card","kind":"poll","url":"https://example.com/p"}"#) == .text("https://example.com/p"))
    }

    @Test func aPersonsCardGoesAsText() {
        #expect(HomeCoreMapping.parts([.card(.signIn(site: "linkedin.com"))]) == [.text("Secure Store: sign in to linkedin.com", runs: [])])
    }

    @Test func aPageUsesTheSignInOfItsSiteOrAParentDomain() {
        #expect(ChiefSecureStore.matches(host: "linkedin.com", site: "linkedin.com"))
        #expect(ChiefSecureStore.matches(host: "www.LinkedIn.com.", site: "linkedin.com"))
        #expect(!ChiefSecureStore.matches(host: "evillinkedin.com", site: "linkedin.com"), "a suffix is not a subdomain")
        #expect(!ChiefSecureStore.matches(host: "linkedin.com", site: "www.linkedin.com"), "a parent never uses a child's sign-in")
        #expect(!ChiefSecureStore.matches(host: "linkedin.com.evil.io", site: "linkedin.com"))
        #expect(ChiefSecureStore.bestSite(forHost: "mail.google.com", among: ["google.com", "mail.google.com", "x.com"]) == "mail.google.com")
        #expect(ChiefSecureStore.bestSite(forHost: "docs.google.com", among: ["google.com", "mail.google.com"]) == "google.com")
        #expect(ChiefSecureStore.bestSite(forHost: "example.org", among: ["google.com"]) == nil)
    }

    @Test func onlyDNSNamesAreSites() {
        #expect(ChiefSecureStore.normalized(" LinkedIn.com. ") == "linkedin.com")
        #expect(ChiefSecureStore.normalized("localhost") == nil)
        #expect(ChiefSecureStore.normalized("a..b") == nil)
        #expect(ChiefSecureStore.normalized("exa mple.com") == nil)
        #expect(ChiefSecureStore.normalized("https://linkedin.com") == nil)
    }
}
