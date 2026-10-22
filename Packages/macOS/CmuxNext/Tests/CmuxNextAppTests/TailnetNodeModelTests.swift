@testable import CmuxNextServer
import Foundation
import Testing

/// This Mac on Your Tailnet (Labs): the card walks signed out, sign-in started with its link,
/// signed in with an address, signed out again; "Limit access to your Tailscale account" starts on
/// (`allow_tailnet_members` false); a Pair link carries the address and a #23297 ticket and reads
/// back the same.
@MainActor @Suite struct TailnetNodeModelTests {
    final class Fake {
        var loginAnswers: [TailnetNodeState] = []
        var logoutAnswer = TailnetNodeState(state: "needs_login")
        var opened: [String] = []
        var minted: [String] = []
        var stored: TailnetAccess?
        var saved: [TailnetAccess] = []
        var mintError: (any Error)?

        func services() -> TailnetNodeServices {
            TailnetNodeServices(
                loginStart: { self.loginAnswers.removeFirst() },
                logout: { self.logoutAnswer },
                openURL: { self.opened.append($0) },
                mintTicket: { address in
                    if let error = self.mintError { throw error }
                    self.minted.append(address)
                    return Self.ticket
                },
                loadAccess: { self.stored },
                saveAccess: { self.saved.append($0) })
        }

        static let ticket = "cmxt1.eyJ2IjoxLCJ1Ijoid3NzOi8vbWFjLWNtdXgudGFpbDEudHMubmV0In0"
    }

    static let link = "https://login.tailscale.com/a/abc123"
    static let running = TailnetNodeState(state: "running", dnsName: "mac-cmux.tail1.ts.net.",
                                          owner: .init(loginName: "me@example.com", displayName: "Me"))

    @Test func signedOutThenLinkThenSignedInThenSignedOut() async {
        let fake = Fake()
        fake.loginAnswers = [TailnetNodeState(state: "needs_login", browseToURL: Self.link)]
        let model = TailnetNodeModel(services: fake.services())
        #expect(model.phase == .unavailable, "nothing is known before the daemon answers")

        model.apply(TailnetNodeState(state: "needs_login", browseToURL: Self.link))
        #expect(model.phase == .signedOut, "a link the node offers by itself is not shown before Sign In")

        await model.signIn()
        #expect(model.phase == .waitingForBrowser(url: Self.link))
        #expect(fake.opened == [Self.link], "Sign In opens the link in the browser")

        await model.signIn()
        #expect(fake.opened == [Self.link, Self.link], "Reopen opens the same link again")

        model.apply(Self.running)
        #expect(model.phase == .signedIn(address: "https://mac-cmux.tail1.ts.net", login: "me@example.com"))

        await model.signOut()
        #expect(model.phase == .signedOut)
    }

    @Test func cancelLeavesTheLinkUnusedAndAStaleLinkStaysHidden() async {
        let fake = Fake()
        fake.loginAnswers = [TailnetNodeState(state: "needs_login", browseToURL: Self.link)]
        let model = TailnetNodeModel(services: fake.services())
        await model.signIn()
        model.cancelSignIn()
        #expect(model.phase == .signedOut)
        model.apply(TailnetNodeState(state: "needs_login", browseToURL: Self.link))
        #expect(model.phase == .signedOut, "after Cancel the node's link is not shown again")
    }

    @Test func otherStates() {
        let phase = { (state: TailnetNodeState, asked: Bool) in TailnetNodeModel.phase(of: state, signInRequested: asked) }
        #expect(phase(TailnetNodeState(state: "needs_machine_auth"), false) == .needsApproval)
        #expect(phase(TailnetNodeState(state: "starting"), true) == .starting)
        #expect(phase(TailnetNodeState(state: "running"), false) == .starting, "running without a name yet")
        #expect(phase(TailnetNodeState(state: "error", error: "boom"), false) == .failed("boom"))
        #expect(phase(TailnetNodeState(state: "needs_login", browseToURL: "http://evil.example"), true) == .signedOut,
                "only an https link is opened")
    }

    @Test func limitAccessIsOnByDefault() throws {
        let fake = Fake()
        let model = TailnetNodeModel(services: fake.services())
        #expect(model.access == TailnetAccess())
        #expect(model.access.limitedToAccount)
        #expect(!model.access.allowTailnetMembers)
        // A stored value without the field keeps the default.
        let decoded = try JSONDecoder().decode(TailnetAccess.self, from: Data(#"{"allow":["user:a@b.c"]}"#.utf8))
        #expect(decoded.limitedToAccount)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(TailnetAccess())) as? [String: Any]
        #expect(encoded?["allow_tailnet_members"] as? Bool == false, "the node's field name")

        model.setLimitedToAccount(false)
        #expect(fake.saved.last?.allowTailnetMembers == true)
        model.setLimitedToAccount(true)
        #expect(fake.saved.last?.allowTailnetMembers == false)
    }

    @Test func pairMintsATicketForTheAddressAndSigningOutDropsIt() async {
        let fake = Fake()
        fake.logoutAnswer = TailnetNodeState(state: "needs_login")
        let model = TailnetNodeModel(services: fake.services())
        await model.pair()
        #expect(fake.minted.isEmpty, "no Pair before sign-in")
        model.apply(Self.running)
        await model.pair()
        #expect(fake.minted == ["https://mac-cmux.tail1.ts.net"])
        #expect(model.pairLink?.ticket == Fake.ticket)
        await model.signOut()
        #expect(model.pairLink == nil)
    }

    @Test func pairFailureShowsItsWords() async {
        struct Refused: LocalizedError { var errorDescription: String? { "no listener" } }
        let fake = Fake()
        fake.mintError = Refused()
        let model = TailnetNodeModel(services: fake.services())
        model.apply(Self.running)
        await model.pair()
        #expect(model.pairLink == nil)
        #expect(model.actionError == "no listener")
    }

    @Test func pairLinkRoundTrip() throws {
        let link = try #require(TailnetPairLink(address: "mac-cmux.tail1.ts.net", ticket: Fake.ticket))
        #expect(link.address == "https://mac-cmux.tail1.ts.net")
        #expect(link.url.hasPrefix("cmux://pair?"))
        let read = try #require(TailnetPairLink(link: "  " + link.url + "\n"))
        #expect(read == link)
    }

    @Test func pairLinkRefusesWhatIsNotOne() {
        #expect(TailnetPairLink(link: "https://pair?address=x&ticket=cmxt1.a") == nil)
        #expect(TailnetPairLink(link: "cmux://pair?address=mac.ts.net") == nil)
        #expect(TailnetPairLink(address: "mac.ts.net", ticket: "cmxt2.abc") == nil)
        #expect(TailnetPairLink(address: "mac.ts.net", ticket: "cmxt1.a b") == nil)
        #expect(TailnetPairLink(address: "mac.ts.net", ticket: "cmxt1." + String(repeating: "a", count: 2048)) == nil)
    }

    @Test func addressesAreCanonical() {
        #expect(TailnetPairLink.canonicalAddress("Mac-CMUX.tail1.ts.net.") == "https://mac-cmux.tail1.ts.net")
        #expect(TailnetPairLink.canonicalAddress("https://mac.tail1.ts.net/") == "https://mac.tail1.ts.net")
        #expect(TailnetPairLink.canonicalAddress("http://mac.tail1.ts.net") == nil)
        #expect(TailnetPairLink.canonicalAddress("https://mac.tail1.ts.net:8443") == nil)
        #expect(TailnetPairLink.canonicalAddress("https://u@mac.tail1.ts.net") == nil)
        #expect(TailnetPairLink.canonicalAddress("https://mac.tail1.ts.net/x") == nil)
        #expect(TailnetPairLink.canonicalAddress("") == nil)
    }
}
