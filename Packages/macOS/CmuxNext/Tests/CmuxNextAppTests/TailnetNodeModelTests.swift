@testable import CmuxNextServer
import Foundation
import Testing

/// This Mac on Your Tailnet (Labs): the card walks signed out, sign-in started with its link,
/// signed in with an address, signed out again; "Limit access to your Tailscale account" starts on
/// (`allow_tailnet_members` false) and is read only until the node reads it; Pair shows the
/// `cmux host join` line for a #23297 ticket; the state read stops when Labs turns off.
@MainActor @Suite struct TailnetNodeModelTests {
    final class Fake {
        var loginAnswers: [TailnetNodeState] = []
        var logoutAnswer = TailnetNodeState(state: "needs_login")
        var opened: [String] = []
        var minted: [String] = []
        var stored: TailnetAccess?
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
                loadAccess: { self.stored })
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

    @Test func aDelayedLoginReplyCannotOverwriteNewerStreamedState() async {
        let fake = Fake()
        let (started, notify) = AsyncStream<Void>.makeStream()
        let (answers, reply) = AsyncStream<TailnetNodeState>.makeStream()
        var services = fake.services()
        services.loginStart = {
            notify.yield(())
            var responses = answers.makeAsyncIterator()
            return await responses.next() ?? TailnetNodeState(state: "needs_login")
        }
        let model = TailnetNodeModel(services: services)
        let signingIn = Task { await model.signIn() }
        var starts = started.makeAsyncIterator()
        _ = await starts.next()
        model.apply(Self.running)
        reply.yield(TailnetNodeState(state: "needs_login", browseToURL: Self.link))
        reply.finish()
        await signingIn.value
        notify.finish()
        #expect(model.phase == .signedIn(address: "https://mac-cmux.tail1.ts.net", login: "me@example.com"))
        #expect(fake.opened.isEmpty, "a reply older than the Running stream item cannot open sign-in again")
    }

    @Test func aSignInLinkFirstSeenOnTheStreamStillOpensTheBrowserOnce() async {
        let fake = Fake()
        let (started, notify) = AsyncStream<Void>.makeStream()
        let (answers, reply) = AsyncStream<TailnetNodeState>.makeStream()
        var services = fake.services()
        services.loginStart = {
            notify.yield(())
            var responses = answers.makeAsyncIterator()
            return await responses.next() ?? TailnetNodeState(state: "needs_login")
        }
        let model = TailnetNodeModel(services: services)
        let signingIn = Task { await model.signIn() }
        var starts = started.makeAsyncIterator()
        _ = await starts.next()
        model.apply(TailnetNodeState(state: "starting"))
        reply.yield(TailnetNodeState(state: "needs_login", browseToURL: Self.link))
        reply.finish()
        await signingIn.value
        model.apply(TailnetNodeState(state: "needs_login", browseToURL: Self.link))
        model.apply(TailnetNodeState(state: "needs_login", browseToURL: Self.link))
        notify.finish()
        #expect(fake.opened == [Self.link], "the requested browser open is consumed once by the current link")
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
        // A stored choice is only read (the node does not read it yet; nothing writes it).
        fake.stored = TailnetAccess(allowTailnetMembers: true)
        #expect(!TailnetNodeModel(services: fake.services()).access.limitedToAccount)
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
        #expect(model.pairCode?.ticket == Fake.ticket)
        await model.signOut()
        #expect(model.pairCode == nil)
    }

    @Test func pairFailureShowsItsWords() async {
        struct Refused: LocalizedError { var errorDescription: String? { "no listener" } }
        let fake = Fake()
        fake.mintError = Refused()
        let model = TailnetNodeModel(services: fake.services())
        model.apply(Self.running)
        await model.pair()
        #expect(model.pairCode == nil)
        #expect(model.actionError == "no listener")
    }

    @Test(arguments: ["signed_out", "disconnected", "replacement", "dismissed", "unchanged"])
    func latePairReplyCannotRestoreAnOldCredential(change: String) async {
        let fake = Fake()
        let (started, notify) = AsyncStream<Void>.makeStream()
        let (tickets, reply) = AsyncStream<String>.makeStream()
        var services = fake.services()
        services.mintTicket = { _ in
            notify.yield(())
            var replies = tickets.makeAsyncIterator()
            return await replies.next() ?? ""
        }
        let model = TailnetNodeModel(services: services)
        model.apply(Self.running)
        let pairing = Task { await model.pair() }
        var starts = started.makeAsyncIterator()
        _ = await starts.next()
        switch change {
        case "signed_out": model.apply(TailnetNodeState(state: "needs_login"))
        case "disconnected": model.markUnavailable()
        case "replacement": model.apply(TailnetNodeState(state: "running", dnsName: "replacement.tail1.ts.net"))
        case "unchanged": model.apply(Self.running)
        default: model.closePair()
        }
        reply.yield(Fake.ticket)
        reply.finish()
        await pairing.value
        notify.finish()
        if change == "unchanged" {
            #expect(model.pairCode?.ticket == Fake.ticket, "an identical state cannot discard a valid Pair result")
        } else {
            #expect(model.pairCode == nil, "a late Pair result must not restore a credential after \(change)")
        }
    }

    @Test func pairShowsTheJoinCommandForTheTicket() throws {
        let code = try #require(TailnetPairCode(address: "mac-cmux.tail1.ts.net", ticket: Fake.ticket))
        #expect(code.address == "https://mac-cmux.tail1.ts.net")
        #expect(code.joinCommand == "cmux host join '\(Fake.ticket)'", "the line #23297's cmux host join takes")
        #expect(TailnetPairCode(address: "mac.ts.net", ticket: "cmxt2.abc") == nil)
        #expect(TailnetPairCode(address: "mac.ts.net", ticket: "cmxt1.a b") == nil)
        #expect(TailnetPairCode(address: "mac.ts.net", ticket: "cmxt1.a'b") == nil, "nothing that could leave the quotes")
        #expect(TailnetPairCode(address: "mac.ts.net", ticket: "cmxt1." + String(repeating: "a", count: 2048)) == nil)
        #expect(TailnetPairCode(address: "http://mac.ts.net", ticket: Fake.ticket) == nil)
    }

    @Test func labsOffStopsTheStateRead() async {
        let model = TailnetNodeModel(services: Fake().services())
        let follower = TailnetStateFollower(model: model)
        let (states, feed) = AsyncStream<TailnetNodeState>.makeStream()
        let ended = Flag(), opens = Counter()
        feed.onTermination = { _ in ended.set() }
        let key = ObjectIdentifier(model)
        follower.follow(key: key) { opens.count += 1; return states }
        follower.follow(key: key) { opens.count += 1; return states }
        feed.yield(Self.running)
        for _ in 0..<50 where model.phase == .unavailable { await Task.yield() }
        #expect(model.phase == .signedIn(address: "https://mac-cmux.tail1.ts.net", login: "me@example.com"))
        #expect(opens.count == 1, "one read per connection")
        follower.stop()
        #expect(!follower.isFollowing)
        for _ in 0..<50 where !ended.isSet { await Task.yield() }
        #expect(ended.isSet, "stopping cancels the stream, which sends stream.cancel")
    }

    @Test func addressesAreCanonical() {
        #expect(TailnetPairCode.canonicalAddress("Mac-CMUX.tail1.ts.net.") == "https://mac-cmux.tail1.ts.net")
        #expect(TailnetPairCode.canonicalAddress("https://mac.tail1.ts.net/") == "https://mac.tail1.ts.net")
        #expect(TailnetPairCode.canonicalAddress("http://mac.tail1.ts.net") == nil)
        #expect(TailnetPairCode.canonicalAddress("https://mac.tail1.ts.net:8443") == nil)
        #expect(TailnetPairCode.canonicalAddress("https://u@mac.tail1.ts.net") == nil)
        #expect(TailnetPairCode.canonicalAddress("https://mac.tail1.ts.net/x") == nil)
        #expect(TailnetPairCode.canonicalAddress("") == nil)
    }
}

@MainActor private final class Counter { var count = 0 }

// NSLock protects every access; stream termination can arrive off the main actor.
private nonisolated final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
