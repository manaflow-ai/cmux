@testable import CmuxNextControl
import CmuxNextSettings
import Darwin
import Foundation
import Testing

/// Whether the linked app FFI has the consent rules (a pin from before them answers nothing). Outside the suites:
/// a suite trait cannot read its own type.
let sessionConsentRulesAnswer = SessionConsentRules().mintCall(
    authWebOrigin: "https://cmux.com",
    ask: SessionConsentAsk(title: "", message: "", allow: "", deny: "", timeout: .seconds(1),
                           declined: ControlError(code: "forbidden", message: "declined"), bundleID: "x", tag: nil)) != nil

/// `auth.session.request`: cmux NIGHTLY asks the person before it mints a NEW session for a same-user cmux app
/// (ad hoc signed included), and refuses another user, a signature that is not the asked bundle id, another
/// backend, and a deny or a timeout. The Security framework, the dialog and the web route are faked; the uid
/// and audit token come from the kernel and every decision from Rust (cmux-cloud-config `handoff`).
@Suite(.serialized, .enabled(if: sessionConsentRulesAnswer, "needs an app FFI with cloud_handoff_*"))
struct SessionConsentTests {
    static let dev = "com.cmuxterm.app.debug.feature1"
    static let project = "prod-project"
    static let mintedAccess = "minted-access-\(UUID().uuidString)"
    static let mintedRefresh = "minted-refresh-\(UUID().uuidString)"

    /// Answers every peer as signed by `identifier` (ad hoc unless `team`).
    struct FakeSigners: SessionConsentSignerReading {
        var identifier: String?
        var team: String?
        func signer(of token: audit_token_t) -> SessionConsentSigner? {
            identifier.map { SessionConsentSigner(identifier: $0, teamID: team, path: "/Users/me/builds/cmux DEV feature1.app") }
        }
    }

    /// The server check of the client: NIGHTLY, team-signed.
    static let nightlyServer = FakeSigners(identifier: SessionConsentClient.nightlyBundleID,
                                           team: SessionConsentClient.teamIdentifier)

    /// What the fakes saw.
    actor Seen {
        var asks: [SessionConsentAsk] = []
        var mints: [SessionConsentMintCall] = []
        func ask(_ ask: SessionConsentAsk) { asks.append(ask) }
        func mint(_ call: SessionConsentMintCall) { mints.append(call) }
    }

    enum Person: Sendable { case allow, deny, never }

    static func nightly(signedIn: Bool = true) -> SessionConsentResponder.Nightly {
        .init(stackProjectID: project, apiOrigin: "https://cloud-api.cmux.dev", authWebOrigin: "https://cmux.com",
              signedIn: signedIn, accountEmail: "person@example.com")
    }

    /// A NIGHTLY control socket (cmuxOnly with an ancestor nobody descends from, so the rest of the socket refuses)
    /// that answers `auth.session.request` with fakes.
    static func makeNightly(identifier: String? = dev, team: String? = nil, uid: uid_t = getuid(), person: Person = .allow,
                            signedIn: Bool = true, seen: Seen, timeout: Duration? = nil) throws -> ControlSocketServer {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        let server = ControlSocketServer(configuration: .init(path: temporarySocketPath(), accessMode: .cmuxOnly,
                                                              trustedAncestor: 999_999), router: router)
        let state = nightly(signedIn: signedIn)
        server.setSessionConsent(SessionConsentResponder(
            uid: uid, signers: FakeSigners(identifier: identifier, team: team),
            nightly: { state },
            consent: { ask in
                await seen.ask(ask)
                switch person {
                case .allow: return true
                case .deny: return false
                case .never:
                    try? await Task.sleep(for: .seconds(3600))
                    return true
                }
            },
            mint: { call in
                await seen.mint(call)
                let body = #"{"accessToken":"\#(mintedAccess)","refreshToken":"\#(mintedRefresh)","expiresAt":"2026-11-26T00:00:00.000Z"}"#
                return (200, Data(body.utf8))
            },
            consentTimeout: timeout))
        try server.start()
        return server
    }

    static func requestLine(bundleID: String = dev, project: String = project) -> String {
        #"{"id":7,"method":"auth.session.request","params":{"bundleId":"\#(bundleID)","tag":"feature1","stackProjectId":"\#(project)","apiOrigin":"https://dev-api.invalid"}}"#
    }

    static func assertNoToken(_ line: String) {
        #expect(!line.contains(mintedAccess) && !line.contains(mintedRefresh), "\(line)")
    }

    @Test func anAdHocSameUserCmuxAppIsAskedAndGetsANewSession() async throws {
        let seen = Seen()
        let server = try Self.makeNightly(seen: seen)
        defer { server.stop() }
        let client = SessionConsentClient(socketPath: server.configuration.path, timeout: .seconds(10),
                                          signers: Self.nightlyServer)
        let tokens = await client.requestTokens(bundleID: Self.dev, tag: "feature1", stackProjectID: Self.project,
                                                apiOrigin: "https://cloud-api.cmux.dev")
        #expect(tokens?.accessToken == Self.mintedAccess)
        #expect(tokens?.refreshToken == Self.mintedRefresh)
        let asks = await seen.asks
        #expect(asks.count == 1)
        let ask = try #require(asks.first)
        #expect(ask.title == "Sign in cmux DEV feature1?")
        #expect(ask.message.contains("/Users/me/builds/cmux DEV feature1.app"))
        #expect(ask.message.contains("ad hoc"))
        #expect(ask.message.contains("person@example.com"))
        #expect(ask.allow == "Sign In")
        #expect(ask.deny == "Don't Allow")
        #expect(ask.timeout == .seconds(120))
        let mint = try #require(await seen.mints.first)
        #expect(mint.url.absoluteString == "https://cmux.com/api/auth/session-handoff")
        let body = try #require(try JSONSerialization.jsonObject(with: mint.body) as? [String: Any])
        let recipient = try #require(body["recipient"] as? [String: Any])
        #expect(recipient["bundleId"] as? String == Self.dev)
        #expect(recipient["tag"] as? String == "feature1")
        // The answer opened nothing else: the rest of the socket still refuses this client.
        #expect(try LineClient(path: server.configuration.path).send("ping") == ControlAuthorizer.accessDenied)
    }

    @Test func theClientSendsNothingToAServerThatIsNotTeamSignedNightly() async throws {
        let seen = Seen()
        let server = try Self.makeNightly(seen: seen)
        defer { server.stop() }
        for signers in [FakeSigners(identifier: SessionConsentClient.nightlyBundleID, team: nil),
                        FakeSigners(identifier: Self.dev, team: SessionConsentClient.teamIdentifier)] {
            let client = SessionConsentClient(socketPath: server.configuration.path, timeout: .seconds(10), signers: signers)
            let tokens = await client.requestTokens(bundleID: Self.dev, tag: "feature1", stackProjectID: Self.project,
                                                    apiOrigin: "https://cloud-api.cmux.dev")
            #expect(tokens == nil)
        }
        #expect(await seen.asks.isEmpty)
    }

    @Test func aSignatureThatIsNotTheAskedBundleIsRefused() async throws {
        let seen = Seen()
        let server = try Self.makeNightly(identifier: "com.cmuxterm.app.debug.other", seen: seen)
        defer { server.stop() }
        let line = try LineClient(path: server.configuration.path).send(Self.requestLine())
        #expect(line.contains("\"forbidden\""), "\(line)")
        #expect(line.contains("com.cmuxterm.app.debug.other"), "\(line)")
        Self.assertNoToken(line)
        #expect(await seen.asks.isEmpty)
        #expect(await seen.mints.isEmpty)
    }

    @Test func anotherUserIsRefused() async throws {
        let seen = Seen()
        let server = try Self.makeNightly(uid: getuid() &+ 1, seen: seen)
        defer { server.stop() }
        let line = try LineClient(path: server.configuration.path).send(Self.requestLine())
        #expect(line.contains("\"forbidden\"") && line.contains("another user"), "\(line)")
        Self.assertNoToken(line)
        #expect(await seen.asks.isEmpty)
    }

    @Test func anotherBackendIsRefusedNamingBoth() async throws {
        let seen = Seen()
        let server = try Self.makeNightly(seen: seen)
        defer { server.stop() }
        let line = try LineClient(path: server.configuration.path).send(Self.requestLine(project: "dev-project"))
        #expect(line.contains("backend_mismatch"), "\(line)")
        for part in ["cloud-api.cmux.dev", Self.project, "dev-api.invalid", "dev-project"] {
            #expect(line.contains(part), "\(part): \(line)")
        }
        Self.assertNoToken(line)
        #expect(await seen.asks.isEmpty)
    }

    @Test func aSignedOutNightlyHasNoSession() async throws {
        let seen = Seen()
        let server = try Self.makeNightly(signedIn: false, seen: seen)
        defer { server.stop() }
        let line = try LineClient(path: server.configuration.path).send(Self.requestLine())
        #expect(line.contains("not_found"), "\(line)")
        #expect(await seen.asks.isEmpty)
    }

    @Test(arguments: [Person.deny, Person.never])
    func aDenyOrNoAnswerIsForbidden(person: Person) async throws {
        let seen = Seen()
        let server = try Self.makeNightly(person: person, seen: seen, timeout: .milliseconds(300))
        defer { server.stop() }
        let line = try LineClient(path: server.configuration.path).send(Self.requestLine())
        #expect(line.contains("\"forbidden\"") && line.contains("declined"), "\(line)")
        Self.assertNoToken(line)
        #expect(await seen.asks.count == 1)
        #expect(await seen.mints.isEmpty)
        // The client reads a refusal as no session.
        #expect(SessionConsentClient.tokens(fromResponse: Data(line.utf8)) == nil)
    }

    @Test func noTokenInAnyRefusal() async throws {
        let seen = Seen()
        for (identifier, uid, project) in [("com.example.app", getuid(), Self.project), (Self.dev, getuid() &+ 1, Self.project),
                                          (Self.dev, getuid(), "other"), ("cmux", getuid(), Self.project)] {
            let server = try Self.makeNightly(identifier: identifier, uid: uid, seen: seen)
            let line = try LineClient(path: server.configuration.path).send(Self.requestLine(project: project))
            server.stop()
            #expect(line.contains("\"ok\":false"), "\(line)")
            Self.assertNoToken(line)
        }
        #expect(await seen.mints.isEmpty)
    }

    @Test func theRealSignerReadsThisProcess() throws {
        // The fleet's test process has a valid signature (ad hoc at least): the any-signature read sees it, with
        // a path.
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { pair.forEach { close($0) } }
        let peer = try #require(pair.first.flatMap(SessionConsentPeer.init(connection:)))
        if let signer = SessionConsentCodeCheck().signer(of: peer.auditToken) {
            #expect(!signer.identifier.isEmpty)
            #expect(signer.path?.isEmpty == false)
        }
    }
}

/// With an app FFI that has no consent rules (a pin from before them), every request is refused and nothing is
/// asked or minted.
@Suite(.enabled(if: !sessionConsentRulesAnswer, "the linked app FFI has cloud_handoff_*"))
struct SessionConsentWithoutRulesTests {
    @Test func everyRequestIsRefused() async throws {
        let seen = SessionConsentTests.Seen()
        let server = try SessionConsentTests.makeNightly(seen: seen)
        defer { server.stop() }
        let line = try LineClient(path: server.configuration.path).send(SessionConsentTests.requestLine())
        #expect(line.contains("unavailable"), "\(line)")
        SessionConsentTests.assertNoToken(line)
        #expect(await seen.asks.isEmpty)
        #expect(await seen.mints.isEmpty)
    }
}
