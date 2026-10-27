import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// The WEBAUTHN relay (p01-process-067, plans/cmux-next/passkeys.md 3.9): every request of the Chromium Host is
/// answered once by token, a refused one with NULL and no system sheet; a cancel or the host's end closes the
/// sheet and sends nothing; the listing permission reaches the host at the start and when it changes.
@MainActor
@Suite struct CEFPlatformPasskeysTests {
    /// Stands in for AuthenticationServices: records the sheets and answers as told.
    final class FakeSystem: ChromiumPlatformPasskeySystem {
        var isAvailable = true
        var permission = ChromiumPasskeyPermission.notDetermined
        var permissionAfterPrompt = ChromiumPasskeyPermission.authorized
        var prompts = 0
        var listed: [ChromiumPlatformCredential] = []
        var started: [(ceremony: ChromiumPasskeyCeremony, anchor: NSWindow)] = []
        var runs: [FakeRun] = []
        /// The result each sheet ends with; nil: it stays open until cancelled.
        var outcome: ((ChromiumPasskeyCeremony) -> ChromiumPasskeyCeremonyResult)?
        /// One element per sheet shown, for a test that waits for it.
        let opened: AsyncStream<Void>
        private let open: AsyncStream<Void>.Continuation

        init() { (opened, open) = AsyncStream.makeStream() }

        func nextSheet() async {
            for await _ in opened { return }
        }

        func requestPermission() async -> ChromiumPasskeyPermission {
            prompts += 1
            permission = permissionAfterPrompt
            return permission
        }

        func credentials(forRelyingParty rpID: String) async -> [ChromiumPlatformCredential] { listed }

        func start(_ ceremony: ChromiumPasskeyCeremony, anchor: NSWindow) -> any ChromiumPasskeyRun {
            started.append((ceremony, anchor))
            let run = FakeRun(outcome: outcome?(ceremony))
            runs.append(run)
            open.yield()
            return run
        }
    }

    final class FakeRun: ChromiumPasskeyRun {
        private(set) var cancelled = false
        private let ended: AsyncStream<ChromiumPasskeyCeremonyResult>
        private let end: AsyncStream<ChromiumPasskeyCeremonyResult>.Continuation

        init(outcome: ChromiumPasskeyCeremonyResult?) {
            (ended, end) = AsyncStream.makeStream()
            if let outcome { end.yield(outcome) }
        }

        func result() async -> ChromiumPasskeyCeremonyResult {
            for await result in ended { return result }
            return .failure(domain: "test", code: 0, description: "")
        }

        func cancel() {
            cancelled = true
            end.yield(.failure(domain: "com.apple.AuthenticationServices.AuthorizationError", code: 1001, description: "cancelled"))
        }
    }

    struct FakeFetcher: ChromiumRelatedOriginFetching {
        var document: Data?
        func wellKnown(for rpID: String) async -> Data? { document }
    }

    /// The replies the relay sends, in order, as a stream a test awaits.
    final class Replies {
        let stream: AsyncStream<(Int64, String?)>
        let sink: AsyncStream<(Int64, String?)>.Continuation
        init() { (stream, sink) = AsyncStream.makeStream() }

        func next() async -> (token: Int64, json: String?)? {
            for await reply in stream { return reply }
            return nil
        }
    }

    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    let system = FakeSystem()
    let replies = Replies()

    func makeRelay(fetcher: FakeFetcher = FakeFetcher()) -> CEFPlatformPasskeys {
        CEFPlatformPasskeys(system: system, publicSuffixes: { ChromiumPasskeyPolicyTests.suffixes }, fetcher: fetcher)
    }

    func send(_ relay: CEFPlatformPasskeys, _ event: ChromiumPlatformPasskeyEvent,
              page: ChromiumPasskeyPage? = ChromiumPasskeyPage(origin: "https://login.example.com", isVisible: true, isAgentDriven: false)) {
        let window = window
        relay.handle(event, pages: { browser in browser == 7 ? page.map { (page: $0, window: Optional(window)) } : nil },
                     reply: { [replies] token, json in replies.sink.yield((token, json)) })
    }

    @Test func anAllowedGetShowsTheSheetOverThePaneWindowAndAnswersByToken() async throws {
        let relay = makeRelay()
        let clientData = Data(ChromiumPasskeyPolicyTests.clientData().utf8)
        system.outcome = { _ in .assertion(credentialID: Data([9]), authenticatorData: Data([1]), signature: Data([2]), userHandle: Data([3]),
                                           clientDataJSON: clientData) }
        send(relay, .request(browser: 7, token: 41, operation: 1, json: ChromiumPasskeyPolicyTests.get()))
        let reply = try #require(await replies.next())
        #expect(reply.token == 41)
        let json = try #require(reply.json)
        #expect(json.contains(#""signature":"Ag""#))
        #expect(system.started.count == 1)
        #expect(system.started.first?.anchor === window)
        let ceremony = try #require(system.started.first?.ceremony)
        #expect(ceremony.rpID == "example.com")
        #expect(ceremony.origin == "https://login.example.com")
        #expect(ceremony.challenge == Data([1, 2, 3]))
        #expect(ceremony.crossOrigin == false)
        #expect(ceremony.kind == .get(allowed: [Data([9])], showsHybridTransport: false))
        #expect(relay.stats.sheets == 1 && relay.stats.answered == 1)
    }

    @Test func aRefusedRequestGetsNullAndNoSheet() async throws {
        let relay = makeRelay()
        send(relay, .request(browser: 7, token: 5, operation: 1, json: ChromiumPasskeyPolicyTests.get()),
             page: ChromiumPasskeyPage(origin: "https://login.example.com", isVisible: false, isAgentDriven: false))
        send(relay, .request(browser: 8, token: 6, operation: 1, json: ChromiumPasskeyPolicyTests.get()))
        send(relay, .request(browser: 7, token: 7, operation: 9, json: "{}"))
        var answers: [Int64: String?] = [:]
        for _ in 0..<3 {
            let reply = try #require(await replies.next())
            answers[reply.token] = reply.json
        }
        #expect(answers.count == 3)
        #expect(answers.values.allSatisfy { $0 == nil })
        #expect(system.started.isEmpty)
        #expect(relay.stats.refused == ["notVisible": 1, "unknownBrowser": 1, "malformed": 1])
    }

    @Test func aMismatchedClientDataIsNeverReturned() async throws {
        let relay = makeRelay()
        system.outcome = { _ in .assertion(credentialID: Data([9]), authenticatorData: Data([1]), signature: Data([2]), userHandle: nil,
                                           clientDataJSON: Data(#"{"type":"webauthn.get"}"#.utf8)) }
        send(relay, .request(browser: 7, token: 8, operation: 1, json: ChromiumPasskeyPolicyTests.get()))
        let reply = try #require(await replies.next())
        #expect(reply.token == 8 && reply.json == nil)
        #expect(relay.stats.refused["clientDataMismatch"] == 1)
    }

    @Test func aCancelClosesTheSheetAndSendsNothing() async throws {
        let relay = makeRelay()
        send(relay, .request(browser: 7, token: 9, operation: 1, json: ChromiumPasskeyPolicyTests.get()))
        // A second request answers with a refusal after the first's sheet opened: the stream's first reply is it.
        send(relay, .request(browser: 8, token: 10, operation: 1, json: ChromiumPasskeyPolicyTests.get()))
        let refused = try #require(await replies.next())
        #expect(refused.token == 10)
        await system.nextSheet()
        send(relay, .cancel(token: 9))
        #expect(system.runs.first?.cancelled == true)
        send(relay, .request(browser: 8, token: 11, operation: 1, json: ChromiumPasskeyPolicyTests.get()))
        let next = try #require(await replies.next())
        #expect(next.token == 11) // nothing was sent for 9
        #expect(relay.stats.cancels == 1)
    }

    @Test func theHostsEndClosesEverySheet() async throws {
        let relay = makeRelay()
        send(relay, .request(browser: 7, token: 12, operation: 0, json: ChromiumPasskeyPolicyTests.create()))
        await system.nextSheet()
        relay.hostEnded()
        #expect(system.runs.first?.cancelled == true)
        send(relay, .request(browser: 8, token: 13, operation: 1, json: ChromiumPasskeyPolicyTests.get()))
        let next = try #require(await replies.next())
        #expect(next.token == 13)
    }

    @Test func aRelatedOriginNeedsCmuxsOwnFetchToListIt() async throws {
        let listed = Data(#"{"origins":["https://login.example.com"]}"#.utf8)
        let allowed = makeRelay(fetcher: FakeFetcher(document: listed))
        let clientData = Data(ChromiumPasskeyPolicyTests.clientData().utf8)
        system.outcome = { _ in .assertion(credentialID: Data([9]), authenticatorData: Data([1]), signature: Data([2]), userHandle: nil,
                                           clientDataJSON: clientData) }
        send(allowed, .request(browser: 7, token: 14, operation: 1, json: ChromiumPasskeyPolicyTests.get(rp: "other.com")))
        #expect(try #require(await replies.next()).json != nil)
        let refused = makeRelay(fetcher: FakeFetcher(document: Data(#"{"origins":["https://elsewhere.com"]}"#.utf8)))
        send(refused, .request(browser: 7, token: 15, operation: 1, json: ChromiumPasskeyPolicyTests.get(rp: "other.com")))
        let reply = try #require(await replies.next())
        #expect(reply.token == 15 && reply.json == nil)
        #expect(system.started.count == 1)
    }

    @Test func theHostGetsThePermissionAtTheStartAndOnEachChange() async throws {
        var sent: [Int32] = []
        let relay = makeRelay()
        relay.hostAttached(setPlatform: { sent.append($0); return 1 })
        relay.hostAttached(setPlatform: { sent.append($0); return 1 })
        #expect(sent == [0]) // once per host, with the launch permission
        let clientData = Data(ChromiumPasskeyPolicyTests.clientData().utf8)
        system.outcome = { _ in .assertion(credentialID: Data([9]), authenticatorData: Data([1]), signature: Data([2]), userHandle: nil,
                                           clientDataJSON: clientData) }
        send(relay, .request(browser: 7, token: 16, operation: 1, json: ChromiumPasskeyPolicyTests.get(requestPermission: true)))
        #expect(try #require(await replies.next()).json?.contains(#""permission":2"#) == true)
        #expect(system.prompts == 1)
        #expect(sent == [0, 2])
        relay.hostEnded()
        system.isAvailable = false
        let without = makeRelay()
        without.hostAttached(setPlatform: { sent.append($0); return 1 })
        #expect(sent == [0, 2]) // no entitlement: the host keeps Chromium's own code
        #expect(!without.stats.handlerSet)
    }

    /// A change in System Settings reaches the host with its next request, before the request runs, as Chromium reads
    /// the state at each request (icloud_keychain.mm `GetAuthState`).
    @Test func aRequestPassesAChangedPermissionFirst() async throws {
        var sent: [Int32] = []
        let relay = makeRelay()
        relay.hostAttached(setPlatform: { sent.append($0); return 1 })
        send(relay, .request(browser: 8, token: 19, operation: 1, json: ChromiumPasskeyPolicyTests.get()))
        _ = await replies.next()
        #expect(sent == [0], "no change, nothing sent")
        system.permission = .denied
        send(relay, .request(browser: 8, token: 20, operation: 1, json: ChromiumPasskeyPolicyTests.get()))
        #expect(sent == [0, 1], "sent in the request's turn")
        _ = await replies.next()
        relay.hostEnded()
        system.permission = .authorized
        send(relay, .request(browser: 8, token: 21, operation: 1, json: ChromiumPasskeyPolicyTests.get()))
        _ = await replies.next()
        #expect(sent == [0, 1], "no host, nothing sent")
    }

    @Test func aListAnswersCredentialsOnlyWhenAuthorized() async throws {
        let relay = makeRelay()
        system.listed = [ChromiumPlatformCredential(credentialID: Data([9]), userHandle: Data([3]), name: "person", providerName: "iCloud")]
        send(relay, .request(browser: 7, token: 17, operation: 2, json: #"{"rp_id":"example.com"}"#))
        #expect(try #require(await replies.next()).json?.contains(#""credentials":[]"#) == true)
        system.permission = .authorized
        send(relay, .request(browser: 7, token: 18, operation: 2, json: #"{"rp_id":"example.com"}"#))
        #expect(try #require(await replies.next()).json?.contains(#""credential_id":"CQ""#) == true)
        #expect(system.started.isEmpty)
    }
}
