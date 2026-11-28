import CmuxMobileModel
import Foundation
import Testing

/// A chat share link is read as the Mac daemon reads it (`agent_session_share_link.rs`), and the
/// page the phone opens carries `in_app=1`, the one-time hand-off code and the guest secret.
@Suite struct ChatShareLinkTests {
    let id = "0123456789abcdefABCD"

    @Test func aGuestLinkKeepsItsSecretAndAnInviteHasNone() throws {
        let guest = try #require(ChatShareLink(url: URL(string: "https://share.cmux.dev/g/\(id)/#abcdefgh")!))
        #expect(guest.page == .guest && guest.shareID == id && guest.secret == "abcdefgh")
        let invite = try #require(ChatShareLink(url: URL(string: "https://SHARE.cmux.dev/i/\(id)#ignored1")!))
        #expect(invite.page == .invite && invite.secret == nil && invite.origin == "https://share.cmux.dev")
        // Links made before the share host still open; they move to it.
        #expect(ChatShareLink(url: URL(string: "https://cmux-platform-production.debussy.workers.dev/i/\(id)")!) != nil)
    }

    @Test func onlyTheShareHostsWellFormedPagesAreLinks() {
        for text in [
            "http://share.cmux.dev/g/\(id)#abcdefgh",
            "https://share.cmux.dev:8443/g/\(id)#abcdefgh",
            "https://user@share.cmux.dev/g/\(id)#abcdefgh",
            "https://share.cmux.dev.evil.example/g/\(id)",
            "https://share.cmux.dev/g/\(id)/extra",
            "https://share.cmux.dev/g/\(id)#short",
            "https://share.cmux.dev/g/has%20space0123456789",
            "cmux://share?link=https%3A%2F%2Fevil.example%2Fg%2F\(id)#abcdefgh",
            "https://cmux.com/g/\(id)",
        ] {
            #expect(ChatShareLink(url: URL(string: text)!) == nil, "\(text)")
        }
    }

    @Test func thePageCarriesTheHandOffAndTheSecret() throws {
        let guest = try #require(ChatShareLink(url: URL(string: "https://share.cmux.dev/g/\(id)#abcdefgh")!))
        #expect(guest.handoffURL.absoluteString == "https://share.cmux.dev/v1/chat-shares/\(id)/handoff")
        let code = "HANDOFF_code-0123456789"
        #expect(guest.pageURL(handoff: code).absoluteString
            == "https://share.cmux.dev/g/\(id)?in_app=1&cmux_handoff=\(code)#abcdefgh")
        #expect(guest.pageURL(handoff: nil).absoluteString == "https://share.cmux.dev/g/\(id)?in_app=1#abcdefgh")
        // A malformed code is dropped: the page opens signed out.
        #expect(guest.pageURL(handoff: "bad code&x=1").absoluteString == "https://share.cmux.dev/g/\(id)?in_app=1#abcdefgh")
    }
}
