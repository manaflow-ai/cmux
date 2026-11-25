import CmuxNextCloud
import CmuxNextCloudUI
import Foundation
import Testing

/// A Cloud start's machine route check (``CloudMachineRoute/prepare(_:)``).
@Suite struct CloudMachineRouteTests {
    private static func machine(printing stdout: String) -> CloudMachineRoute {
        CloudMachineRoute(exec: { _, _ in CloudExecResult(exitCode: 0, stdout: stdout, stderr: "") })
    }

    /// DEV 36050-cloud-multiplayer: a new machine whose image software has no model-route report (it prints
    /// nothing) and that the app's update does not change refused every Cloud start.
    @Test func aMachineWithNoReportStartsOnItsImagesSoftware() async {
        // Until the app's pinned FFI release carries `cloud_machine_route`, the verdict cannot be read and the
        // start is refused as invalid; this passes once the pin moves.
        await withKnownIssue("the pinned FFI release has no cloud_machine_route yet", isIntermittent: true) {
            try await Self.machine(printing: "").prepare {}
        }
    }

    /// With no reading of the chat's agent (an agent Cloud does not serve), only an unrouted machine starts on the chat's
    /// own connection: one that holds a provider login, or whose agent service is down, is refused whatever the chat
    /// carries; without a connection an unrouted one is too.
    @Test func onlyAnUnroutedMachineStartsOnTheChatsOwnConnection() {
        #expect(CloudMachineRoute.starts(.notEdge, carriesConnection: true))
        #expect(!CloudMachineRoute.starts(.notEdge, carriesConnection: false))
        for verdict in [CloudMachineRoute.Verdict.holdsCredential, .noDaemon, .invalid] {
            #expect(!CloudMachineRoute.starts(verdict, carriesConnection: true))
        }
        for carries in [true, false] {
            #expect(CloudMachineRoute.starts(.ready, carriesConnection: carries))
            #expect(CloudMachineRoute.starts(.unsupported, carriesConnection: carries))
        }
    }

    /// cmux#45773: a machine that reports no route, for a chat with no connection of its own, ends the start with Set
    /// up Cloud at once (no update can give it a route), not the dead-end refusal; a login on the machine is still that.
    @Test func aMachineThatReportsNoRouteNeedsTheChatsOwnConnection() async {
        await withKnownIssue("the pinned FFI release has no cloud_machine_route yet", isIntermittent: true) {
            let report = #"{"ok":false,"holds_credential":false,"daemon":{"running":true},"agents":{}}"#
            let updated = UpdateCount()
            await #expect(throws: CloudMachineRoute.NeedsConnection.self) {
                try await Self.machine(printing: report).prepare { await updated.add() }
            }
            #expect(await updated.count == 0)
        }
        // The rule itself, with no FFI: only an unrouted machine for a chat with no connection of its own.
        #expect(CloudMachineRoute.needsConnection(.notEdge, carriesConnection: false))
        #expect(!CloudMachineRoute.needsConnection(.notEdge, carriesConnection: true))
        for verdict in [CloudMachineRoute.Verdict.ready, .unsupported, .invalid, .noDaemon, .holdsCredential] {
            #expect(!CloudMachineRoute.needsConnection(verdict, carriesConnection: false))
        }
    }

    /// A machine-auth report as acpmux prints it (`cli/machine_auth.rs` `report`) on a machine the Cloud service gives no
    /// route: the edge host does not resolve, so no agent has a base URL; `logins` and `variables` are what it holds.
    private static func unrouted(logins: [(path: String, agent: String)] = [], variables: [String] = [], claudeKey: String = "missing",
                                 running: Bool = true) -> String {
        let agent = { (key: String) -> [String: Any] in
            ["base_url": NSNull(), "base_url_source": "missing", "key": key, "key_source": key == "missing" ? "missing" : "daemon", "edge_routed": false]
        }
        let report: [String: Any] = [
            "cloud_vm": true, "edge_host": "coderouter.cmux.internal", "model_plane": ["state": "ok"],
            "daemon": ["running": running, "pid": running ? 4242 as Any : NSNull()],
            "agents": ["claude": agent(claudeKey), "codex": agent("missing")],
            "credential_env": variables, "login_files": logins.map { ["path": $0.path, "agent": $0.agent, "kind": "file"] },
            "holds_credential": !logins.isEmpty || !variables.isEmpty, "managed_route_files": [], "ok": false,
        ]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        return "motd noise\n" + String(decoding: data, as: UTF8.self) + "\n"
    }

    /// cmux#45773: a machine whose Claude signs in by itself (`claude setup-token`'s token in acpmux's env, or its saved
    /// sign-in) starts a Claude chat with no connection of the chat's own and no gateway; Rust calls that machine
    /// ``CloudMachineRoute/Verdict/holdsCredential``, which refused every such start.
    @Test func aMachineWhoseClaudeSignsInStartsAClaudeChatWithNoConnection() throws {
        for report in [Self.unrouted(variables: ["CLAUDE_CODE_OAUTH_TOKEN"]),
                       Self.unrouted(logins: [("~/.claude/.credentials.json", "claude")]),
                       Self.unrouted(claudeKey: "other")] {
            let claude = try #require(CloudMachineRoute.Agent.read(report, family: "claude"))
            #expect(claude == .init(daemonRunning: true, routed: false, signsIn: true))
            #expect(CloudMachineRoute.starts(.holdsCredential, agent: claude, carriesConnection: false))
            #expect(!CloudMachineRoute.needsConnection(.holdsCredential, agent: claude, carriesConnection: false))
            // Codex on that machine has no sign-in of its own: a Codex chat needs its own connection.
            let codex = try #require(CloudMachineRoute.Agent.read(report, family: "codex"))
            #expect(!codex.signsIn)
            #expect(!CloudMachineRoute.starts(.holdsCredential, agent: codex, carriesConnection: false))
            #expect(CloudMachineRoute.needsConnection(.holdsCredential, agent: codex, carriesConnection: false))
            #expect(CloudMachineRoute.starts(.holdsCredential, agent: codex, carriesConnection: true))
        }
    }

    /// The chat's own connection goes with its launch and replaces any login on the machine (acpmux `agent_credentials`
    /// `UNSET`): a machine that holds one starts it too. A machine with nothing for the agent needs a connection; one
    /// whose agent service is down is refused, and says so.
    @Test func aConnectionStartsOnAMachineWithALoginAndADownServiceIsRefused() throws {
        let bare = try #require(CloudMachineRoute.Agent.read(Self.unrouted(), family: "claude"))
        #expect(bare == .init(daemonRunning: true, routed: false, signsIn: false))
        #expect(CloudMachineRoute.needsConnection(.notEdge, agent: bare, carriesConnection: false))
        #expect(CloudMachineRoute.starts(.notEdge, agent: bare, carriesConnection: true))

        let down = try #require(CloudMachineRoute.Agent.read(Self.unrouted(variables: ["CLAUDE_CODE_OAUTH_TOKEN"], running: false), family: "claude"))
        for carries in [true, false] {
            #expect(!CloudMachineRoute.starts(.holdsCredential, agent: down, carriesConnection: carries))
            #expect(!CloudMachineRoute.needsConnection(.holdsCredential, agent: down, carriesConnection: carries))
        }
        #expect(CloudMachineRoute.Refused(verdict: .holdsCredential, agent: down).message == CloudMachineRoute.Refused(verdict: .noDaemon).message)
        #expect(CloudMachineRoute.Agent.read("bash: acp: unknown command\n", family: "claude") == nil)
        #expect(CloudMachineRoute.Agent.read(Self.unrouted(), family: "gemini") == nil)
    }

    /// The whole start on a machine whose Claude signs in by itself: it goes on at once, with no update wait.
    /// Rust judges the machine (the pinned FFI's `cloud_machine_route`, `holds_credential`); no known issue.
    @Test func aStartOnAMachineWhoseClaudeSignsInGoesOnWithNoUpdate() async throws {
        let updated = UpdateCount()
        try await Self.machine(printing: Self.unrouted(variables: ["CLAUDE_CODE_OAUTH_TOKEN"])).prepare(family: "claude") { await updated.add() }
        #expect(await updated.count == 0)
        // The same machine for a Codex chat with no connection: Set up Cloud at once, still no update.
        await #expect(throws: CloudMachineRoute.NeedsConnection.self) {
            try await Self.machine(printing: Self.unrouted(variables: ["CLAUDE_CODE_OAUTH_TOKEN"])).prepare(family: "codex") { await updated.add() }
        }
        #expect(await updated.count == 0)
    }

    /// cmux#45774: a Codex chat on Sign in with ChatGPT carries its connection, but the machine's daemon cannot take a
    /// Codex start credential and the update could not bring it one (no published build yet). The start said "agents
    /// aren't routed through the Cloud service yet"; it says the machine's software is too old.
    @Test func aConnectionTheMachineCannotTakeSaysItsSoftwareIsTooOld() async throws {
        let updated = UpdateCount()
        do {
            try await Self.machine(printing: Self.unrouted()).prepare(serves: { false }, carriesConnection: true, family: "codex") { await updated.add() }
            Issue.record("the start went on with a connection the machine cannot take")
        } catch let failure as CloudMoveFailure {
            #expect(failure.message == CloudMachineRoute.tooOld)
        }
        #expect(await updated.count == 1)
    }

    private actor UpdateCount {
        var count = 0
        func add() { count += 1 }
    }
}
