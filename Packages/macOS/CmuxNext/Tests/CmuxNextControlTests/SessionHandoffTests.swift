@testable import CmuxNextControl
import CmuxNextSettings
import Darwin
import Foundation
import Security
import Testing

/// `auth.session.handoff`: cmux NIGHTLY hands its session only to a same-user, team-signed cmux app,
/// and a DEV build takes one only from a same-user, team-signed NIGHTLY. The Security framework check
/// is faked (fleet test bundles are ad hoc signed); the uid and audit token come from the kernel.
@Suite(.serialized) struct SessionHandoffTests {
    /// Answers as if every peer were signed by `team` with `identifier`.
    struct FakeCodeCheck: SessionHandoffCodeChecking {
        var team: String = SessionHandoffPolicy.teamIdentifier
        var identifier: String?
        func signingIdentifier(of token: audit_token_t, teamIdentifier: String) -> String? {
            teamIdentifier == team ? identifier : nil
        }
    }

    static let refresh = "refresh-\(UUID().uuidString)"
    static let access = "access-\(UUID().uuidString)"
    static let nightlyPair = SessionHandoffPair(accessToken: access, refreshToken: refresh)

    func policy(identifier: String?, team: String = SessionHandoffPolicy.teamIdentifier, uid: uid_t = getuid()) -> SessionHandoffPolicy {
        SessionHandoffPolicy(uid: uid, codeCheck: FakeCodeCheck(team: team, identifier: identifier))
    }

    /// A control socket (in `mode`) that answers the handoff with `serverPolicy` and NIGHTLY's pair.
    func makeNightly(_ serverPolicy: SessionHandoffPolicy, mode: ControlAccessMode = .cmuxOnly,
                     session: SessionHandoffPair? = nightlyPair) throws -> ControlSocketServer {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        // cmuxOnly with an ancestor nobody descends from: the rest of the socket refuses this client.
        let server = ControlSocketServer(configuration: .init(path: temporarySocketPath(), accessMode: mode,
                                                              trustedAncestor: 999_999), router: router)
        server.setSessionHandoff(SessionHandoffResponder(policy: serverPolicy) { session })
        try server.start()
        return server
    }

    func fetch(from server: ControlSocketServer, serverIdentifier: String? = SessionHandoffPolicy.serverBundleID,
               team: String = SessionHandoffPolicy.teamIdentifier, uid: uid_t = getuid()) async -> SessionHandoffPair? {
        await SessionHandoffClient(socketPath: server.configuration.path,
                                   policy: policy(identifier: serverIdentifier, team: team, uid: uid)).fetch()
    }

    @Test func aTeamSignedCmuxAppOfThisUserGetsThePair() async throws {
        let server = try makeNightly(policy(identifier: "com.cmuxterm.app.debug.next"))
        defer { server.stop() }
        let pair = await fetch(from: server)
        #expect(pair == Self.nightlyPair)
        // The handoff opened nothing else: the next line on a fresh connection is refused as before.
        #expect(try LineClient(path: server.configuration.path).send("ping") == ControlAuthorizer.accessDenied)
    }

    @Test func aClientOfAnotherUserIsRefused() async throws {
        let server = try makeNightly(policy(identifier: "com.cmuxterm.app.debug.next", uid: getuid() &+ 1))
        defer { server.stop() }
        #expect(await fetch(from: server) == nil)
        let line = try LineClient(path: server.configuration.path).send(#"{"id":1,"method":"auth.session.handoff"}"#)
        #expect(line.contains("forbidden"))
        #expect(!line.contains(Self.refresh) && !line.contains(Self.access))
    }

    @Test(arguments: [("OTHERTEAM1", "com.cmuxterm.app.debug.next"), (SessionHandoffPolicy.teamIdentifier, "cmux"),
                      (SessionHandoffPolicy.teamIdentifier, "com.cmuxterm.cua"), (SessionHandoffPolicy.teamIdentifier, "com.example.app")])
    func aClientOfAnotherTeamOrNotACmuxAppIsRefused(team: String, identifier: String) async throws {
        let server = try makeNightly(policy(identifier: identifier, team: team))
        defer { server.stop() }
        #expect(await fetch(from: server) == nil)
        let line = try LineClient(path: server.configuration.path).send(#"{"id":1,"method":"auth.session.handoff"}"#)
        #expect(line.contains("session handoff refused"))
        #expect(!line.contains(Self.refresh) && !line.contains(Self.access))
    }

    @Test func anAdHocClientIsRefused() async throws {
        // Ad hoc code has no team: the real check answers nil for it, as the fake does here.
        let server = try makeNightly(policy(identifier: nil))
        defer { server.stop() }
        #expect(await fetch(from: server) == nil)
    }

    @Test func theClientRefusesAServerThatIsNotNightly() async throws {
        let server = try makeNightly(policy(identifier: "com.cmuxterm.app.debug.next"))
        defer { server.stop() }
        #expect(await fetch(from: server, serverIdentifier: "com.cmuxterm.app.debug.next") == nil)
        #expect(await fetch(from: server, team: "OTHERTEAM1") == nil)
        #expect(await fetch(from: server, uid: getuid() &+ 1) == nil)
    }

    @Test func noNightlyOrASignedOutNightlyIsNoSession() async throws {
        let missing = SessionHandoffClient(socketPath: temporarySocketPath(), policy: policy(identifier: SessionHandoffPolicy.serverBundleID))
        #expect(await missing.fetch() == nil)
        let signedOut = try makeNightly(policy(identifier: "com.cmuxterm.app.debug.next"), session: nil)
        defer { signedOut.stop() }
        #expect(await fetch(from: signedOut) == nil)
    }

    @Test func aSocketWithoutAResponderDoesNotKnowTheMethod() async throws {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        let server = ControlSocketServer(configuration: .init(path: temporarySocketPath(), accessMode: .automation), router: router)
        try server.start()
        defer { server.stop() }
        let line = try LineClient(path: server.configuration.path).send(#"{"id":1,"method":"auth.session.handoff"}"#)
        #expect(line.contains("\"ok\":false"))
        #expect(await fetch(from: server) == nil)
    }

    @Test func cmuxAppsAreTheMainAppsOnly() {
        for identifier in ["com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.nightly.cmux-next",
                           "com.cmuxterm.app.debug", "com.cmuxterm.app.debug.next", "com.cmuxterm.app.debug.tag2.part",
                           "com.cmuxterm.app.staging.x1"] {
            #expect(SessionHandoffPolicy.isCmuxApp(identifier), "\(identifier)")
        }
        for identifier in ["cmux", "cmux-app-host", "com.cmuxterm.cua", "com.cmuxterm.app.computer-use", "com.cmuxterm.app.debug.",
                           "com.cmuxterm.app.debug.My", "com.cmuxterm.app.debug.my-tag", "com.cmuxterm.app.debug.cua", "com.cmuxterm.app.debugx", "com.example.app"] {
            #expect(!SessionHandoffPolicy.isCmuxApp(identifier), "\(identifier)")
        }
    }

    @Test func aPairNeverPrintsItsTokens() {
        let pair = Self.nightlyPair
        var dumped = ""
        dump(pair, to: &dumped)
        for text in [String(describing: pair), String(reflecting: pair), "\(String(describing: Optional(pair)))", dumped] {
            #expect(!text.contains(Self.refresh) && !text.contains(Self.access), "\(text)")
        }
    }

    @Test func malformedOrErrorAnswersAreNoSession() {
        #expect(SessionHandoffClient.pair(fromResponse: Data(#"{"ok":false,"error":{"code":"forbidden"}}"#.utf8)) == nil)
        #expect(SessionHandoffClient.pair(fromResponse: Data(#"{"ok":true,"result":{"refresh_token":""}}"#.utf8)) == nil)
        #expect(SessionHandoffClient.pair(fromResponse: Data("not json".utf8)) == nil)
        #expect(SessionHandoffClient.pair(fromResponse: Data(#"{"ok":true,"result":{"refresh_token":"r"}}"#.utf8))
            == SessionHandoffPair(accessToken: nil, refreshToken: "r"))
    }

    @Test func nightlysSocketIsTheOneItsLaunchIdentityNames() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(SessionHandoffClient.nightlySocketPath(home: home) == "/Users/someone/.local/state/cmux/cmux-nightly.sock")
    }

    @Test func theRealCheckRefusesThisAdHocTestProcess() throws {
        // The fleet's test bundle is ad hoc signed: the Security framework check finds no team for it.
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { pair.forEach { close($0) } }
        let peer = try #require(pair.first.flatMap(SessionHandoffPeer.init(connection:)))
        #expect(peer.uid == getuid())
        #expect(SessionHandoffCodeCheck().signingIdentifier(of: peer.auditToken, teamIdentifier: SessionHandoffPolicy.teamIdentifier) == nil)
        #expect(!SessionHandoffPolicy().admitsClient(peer))
        #expect(!SessionHandoffPolicy().admitsServer(peer))
    }

    @Test func onlyHardenedUndebuggableCodeCounts() {
        let runtime = NSNumber(value: SecCodeSignatureFlags.runtime.rawValue)
        let hardened: NSDictionary = [kSecCodeInfoFlags as String: runtime]
        let plain: NSDictionary = [kSecCodeInfoFlags as String: NSNumber(value: 0)]
        let debuggable: NSDictionary = [kSecCodeInfoFlags as String: runtime,
                                        kSecCodeInfoEntitlementsDict as String: ["com.apple.security.get-task-allow": true]]
        #expect(SessionHandoffCodeCheck.isHardened(hardened))
        #expect(!SessionHandoffCodeCheck.isHardened(plain))
        #expect(!SessionHandoffCodeCheck.isHardened(debuggable))
    }
}
