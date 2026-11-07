import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextDaemonService
import Foundation
import Testing

/// An invite is one daemon call (`agent-session-share-invite-chat`, follow-up on #33746): the daemon
/// finds the chat's invite share or makes it with the account on it, so `cmux share invite`, its MCP
/// tool and the Invite People sheet never list, create, invite and revoke on their own. The owner's
/// token is asked for only when the daemon must make the share in a hosted room.
@MainActor @Suite(.serialized, .closesItsWindows)
struct AgentShareInviteChatTests {
    /// The fixture's chats, on `connection`; records whether the owner's token was asked for.
    @MainActor final class Host: AgentShareHost {
        let services: AppServices
        let connection: DaemonConnection
        var tokensAsked = 0

        init(_ services: AppServices, connection: DaemonConnection) {
            self.services = services
            self.connection = connection
        }

        func shareTab(surface: SurfaceID) -> TabModel? { services.shareTab(surface: surface) }
        func shareTab(id: String) -> TabModel? { services.shareTab(id: id) }
        func shareTabID(showing session: String) -> String? { services.shareTabID(showing: session) }
        var shareFocusedTabID: String? { nil }
        func shareConnection(holding tab: TabModel) -> DaemonConnection? { connection }
        func shareIsOnThisMac(_ tab: TabModel) -> Bool { true }
        var shareLocalConnection: DaemonConnection? { connection }
        func shareOwnerToken(api: URL?) async -> String? {
            tokensAsked += 1
            return "owner-token"
        }
        func shareCopy(_ text: String) {}
        func shareNotice(_ message: String) {}
        func shareAskOwner(_ ask: AgentShareConsentAsk) async -> Bool { true }
    }

    private struct Calls: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-share-calls"
    }

    /// A daemon that records every share frame. `mode` `local` answers the invite; `room` refuses an
    /// invite with no owner token (`share.needs_sign_in`), as a daemon bridged to a room does when it
    /// must make the share; `refuse` answers `share.bad_request`.
    private static let script = #"""
    import json, sys
    mode = sys.argv[1]
    calls = []
    print('{"ok":true}', file=sys.stderr, flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        cmd = frame.get('cmd')
        reply = {'id': frame.get('id'), 'ok': True, 'data': {}}
        if cmd == 'identify':
            reply['data'] = {'app': 'cmux-tui', 'protocol': 12, 'generation': 'share-boot', 'capabilities': []}
        elif cmd == 'test-share-calls':
            reply['data'] = calls
        elif cmd is not None and cmd.startswith('agent-session-share-'):
            calls.append(frame)
            if cmd == 'agent-session-share-room':
                reply['data'] = {'room': 'https://room.example', 'owner_api': None}
            elif cmd != 'agent-session-share-invite-chat':
                reply = {'id': frame.get('id'), 'ok': False, 'error': 'unexpected', 'error_code': 'share.bad_request'}
            elif mode == 'refuse' or (mode == 'room' and 'owner_token' not in frame):
                code = 'share.bad_request' if mode == 'refuse' else 'share.needs_sign_in'
                reply = {'id': frame.get('id'), 'ok': False, 'error': code, 'error_code': code}
            else:
                url = 'https://room.example/i/s1' if mode == 'room' else None
                reply['data'] = {'share_id': 's1', 'account': frame['account'].strip().lower(), 'role': frame.get('role', 'talk'),
                    'state': 'invited', 'invite_url': url, 'created_share': True, 'expires_at': 7}
        print(json.dumps(reply), flush=True)
    """#

    private static func daemon(_ mode: String) async throws -> DaemonConnection {
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", script, mode])
        let endpoint = DaemonEndpoint(socketPath: "/tmp/cmux-share-invite-\(UUID().uuidString).sock", bridge: bridge)
        let connection = DaemonConnection(endpoint: endpoint, configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
        try await connection.start()
        return connection
    }

    private static func calls(_ connection: DaemonConnection) async throws -> [JSONValue] {
        try await connection.request(Calls()).arrayValue ?? []
    }

    private static func command(_ call: JSONValue) -> String? { call["cmd"]?.stringValue }

    private static func invite(_ registry: ActionRegistry, account: String, role: String? = nil, ttl: String? = nil)
        async -> Result<[String: ActionResultValue], ActionWorkFailure>? {
        var arguments: [String: ActionValue] = ["surface": .int(1), "account": .string(account)]
        if let role { arguments["role"] = .string(role) }
        if let ttl { arguments["ttl"] = .string(ttl) }
        // What `cmux share invite` sends: a CLI run through the control socket.
        var invocation = ActionInvocation(target: nil, arguments: arguments, origin: .cli)
        invocation.viaControlSocket = true
        let run = registry.capturingRun { _ = registry.perform(AgentShareActions.invite, invocation: invocation) }
        guard let result = run.results.first else { return nil }
        return await result.value
    }

    /// `cmux share invite` is one call that names the chat (its surface and session), the account and
    /// the role, and answers what the daemon answered; no owner token is minted for it.
    @Test func aCLIInviteIsOneDaemonCall() async throws {
        let f = AgentShareTests.fixture()
        let connection = try await Self.daemon("local")
        defer { Task { await connection.close() } }
        let host = Host(f.services, connection: connection)
        let registry = ActionRegistry.standard()
        AgentShareActions(host: host).bind(into: registry)
        guard case .success(let result)? = await Self.invite(registry, account: "Ann@Example.com", role: "view", ttl: "2h") else {
            Issue.record("the invite ran"); return
        }
        #expect(result["share_id"] == .string("s1") && result["account"] == .string("ann@example.com"))
        #expect(result["role"] == .string("view") && result["created_share"] == .bool(true))
        let calls = try await Self.calls(connection)
        #expect(calls.compactMap(Self.command) == ["agent-session-share-invite-chat"], "no list, create or revoke")
        let call = try #require(calls.first)
        #expect(call["surface"] == .number(1) && call["session"] == .string(AgentShareTests.session))
        #expect(call["account"] == .string("Ann@Example.com") && call["role"] == .string("view"))
        #expect(call["ttl_secs"] == .number(7200))
        #expect(call["owner_token"] == nil)
        #expect(host.tokensAsked == 0, "no share was made in a room, so no token")
    }

    /// When the daemon must make the share in its hosted room it asks for the owner's sign-in: the
    /// token is minted then, for the room's API, and the same invite is asked once more with it.
    @Test func theOwnersTokenIsMintedOnlyWhenTheDaemonMakesARoomShare() async throws {
        let f = AgentShareTests.fixture()
        let connection = try await Self.daemon("room")
        defer { Task { await connection.close() } }
        let host = Host(f.services, connection: connection)
        let chat = AgentShareChat(surface: 1, session: AgentShareTests.session, connection: connection, title: "Fix the build")
        let result = try await AgentShareActions.inviteWork(chat, account: "@theo", role: "talk", ttl: nil, host: host)
        #expect(result["invite_url"] == .string("https://room.example/i/s1"))
        let calls = try await Self.calls(connection)
        #expect(calls.compactMap(Self.command) == ["agent-session-share-invite-chat", "agent-session-share-room", "agent-session-share-invite-chat"])
        #expect(calls.last?["owner_token"] == .string("owner-token"))
        #expect(calls.first?["create_id"] == calls.last?["create_id"], "the retry is the same invite")
        #expect(calls.first?["ttl_secs"] == nil, "the daemon's default lifetime for an invite share")
        #expect(host.tokensAsked == 1)
    }

    /// The daemon's refusal of the account's shape reads as a bad account, and nothing else is asked
    /// (the daemon left no share to end).
    @Test func aRefusedInviteAsksNothingMore() async throws {
        let f = AgentShareTests.fixture()
        let connection = try await Self.daemon("refuse")
        defer { Task { await connection.close() } }
        let host = Host(f.services, connection: connection)
        let chat = AgentShareChat(surface: 1, session: AgentShareTests.session, connection: connection, title: "Fix the build")
        await #expect(throws: AgentShareBadAccount.self) {
            try await AgentShareActions.inviteWork(chat, account: "ann", role: "talk", ttl: nil, host: host)
        }
        #expect(try await Self.calls(connection).compactMap(Self.command) == ["agent-session-share-invite-chat"])
    }
}
