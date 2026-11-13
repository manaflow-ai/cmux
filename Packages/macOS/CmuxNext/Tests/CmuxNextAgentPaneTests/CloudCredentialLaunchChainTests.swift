import CmuxNextCloud
@testable import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A Cloud chat's start runs on the connection its Cloud first use chose, end to end (lane F,
/// cmux-tui/docs/model-connections.md Revision 2): `CloudSetup.admit` picks it once at the send, the
/// machine chat's seed carries it, the machine start reads that connection's credential from this
/// Mac's acpmux, and the start's params carry its variable, id and expiry to the owner's machine.
@Suite
@MainActor
struct CloudCredentialLaunchChainTests {
    private static let expires = Date(timeIntervalSince1970: 1_900_000_000)

    private func start(harness: String, account: String? = nil) throws -> AgentPaneCloudStart {
        var params: [String: Any] = ["task": "Fix the build", "key": UUID().uuidString, "harness": harness]
        if let account { params["account"] = account }
        return try #require(AgentPaneCloudStart(params: params))
    }

    private func setup(_ personal: [CloudSetup.Connection], organization: Set<String> = []) -> CloudSetup {
        CloudSetup(read: { CloudSetup.Snapshot(personal: personal, organization: organization) })
    }

    @Test func theChosenConnectionsCredentialReachesTheMachineStart() async throws {
        var asked: [String] = []
        let credentials = CloudAgentCredentials { id in
            asked.append(id)
            return Data(#"{"family":"codex","kind":"chatgpt-plan","env":{"CMUX_CHATGPT_ACCESS_TOKEN":"eyJ.abc.sig"},"expires_at":1900000000}"#.utf8)
        }
        let cloud = setup([CloudSetup.Connection(id: "openai-key", families: ["codex"]), CloudSetup.Connection(id: "chatgpt-1", families: ["codex"])])
        // The picker's account serves Cloud: the start runs on it, computed once at the send.
        let (admitted, refusal) = await cloud.admit(try start(harness: "codex", account: "chatgpt-1"))
        #expect(refusal == nil)
        #expect(admitted.connection == "chatgpt-1")
        // The machine chat's seed carries the choice to its start on the machine.
        let seed = admitted.seed(cwd: "/home/cmux/work/app")
        #expect(seed.cloudConnection == "chatgpt-1")
        let credential = try #require(try await credentials.launchCredential(connection: seed.cloudConnection, family: CloudSetup.family(of: seed.harness),
                                                                             refusal: CloudAgentCredentials.Failure.unavailable(connection: "x"),
                                                                             mismatch: CloudAgentCredentials.Failure.unavailable(connection: "mismatch")))
        #expect(asked == ["chatgpt-1"])
        let params = AgentSessionAttachClient.startParams(cwd: nil, harness: seed.harness, homeConfirmed: false, personKey: nil, servesKeyedReason: false,
                                                          callerOwnsVM: true, servesVMKind: true, servesCredentials: true, credentials: credential.launch)
        let wire = try #require(params["credentials"] as? [String: any Sendable])
        #expect(wire["env"] as? [String: String] == ["CMUX_CHATGPT_ACCESS_TOKEN": "eyJ.abc.sig"])
        #expect(wire["connection"] as? String == "chatgpt-1")
        #expect(wire["expires_at"] as? Int64 == 1_900_000_000)
        #expect(credential.expiresAt == Self.expires)
        // Never to a machine that is not the caller's own, nor to a daemon that takes no credential.
        #expect(AgentSessionAttachClient.startParams(cwd: nil, harness: "codex", homeConfirmed: false, personKey: nil, servesKeyedReason: false,
                                                     callerOwnsVM: false, servesVMKind: true, servesCredentials: true, credentials: credential.launch)["credentials"] == nil)
        #expect(AgentSessionAttachClient.startParams(cwd: nil, harness: "codex", homeConfirmed: false, personKey: nil, servesKeyedReason: false,
                                                     callerOwnsVM: true, servesVMKind: true, servesCredentials: false, credentials: credential.launch)["credentials"] == nil)
    }

    @Test func noAccountTakesTheFamilysFirstServingConnectionAndATeamKeyNone() async throws {
        let claude = try start(harness: "claude")
        let cloud = setup([CloudSetup.Connection(id: "codex-only", families: ["codex"]), CloudSetup.Connection(id: "claude-token", families: ["claude"])])
        let chosen = await cloud.admit(claude).start
        #expect(chosen.connection == "claude-token")
        let (onTeam, refusal) = await setup([], organization: ["claude"]).admit(claude)
        #expect(refusal == nil, "the team's key serves")
        #expect(onTeam.connection == nil, "the team's key: the machine's own route")
        #expect(onTeam.seed(cwd: nil).cloudConnection == nil)
        let none = await setup([], organization: []).admit(claude)
        #expect(none.refusal != nil, "Set up Cloud instead of a start")
    }

    @Test func anAgentSwitchedAfterTheChoiceOrAnUnreadableConnectionNeverSendsAnotherCredential() async throws {
        let credentials = CloudAgentCredentials { _ in
            Data(#"{"family":"claude","kind":"claude-token","env":{"CLAUDE_CODE_OAUTH_TOKEN":"sk-ant-oat01-abc"},"expires_at":null}"#.utf8)
        }
        let refusal = CloudAgentCredentials.Failure.unavailable(connection: "refused")
        let mismatch = CloudAgentCredentials.Failure.unavailable(connection: "mismatch")
        #expect(try await credentials.launchCredential(connection: nil, family: "claude", refusal: refusal, mismatch: mismatch) == nil, "no choice")
        await #expect(throws: mismatch, "switched to Codex: refused, never the machine's own route") {
            try await credentials.launchCredential(connection: "claude-token", family: "codex", refusal: refusal, mismatch: mismatch)
        }
        let unreadable = CloudAgentCredentials { _ in Data(#"{"error":"signed_out"}"#.utf8) }
        await #expect(throws: refusal) { try await unreadable.launchCredential(connection: "claude-token", family: "claude", refusal: refusal, mismatch: mismatch) }
    }
}
