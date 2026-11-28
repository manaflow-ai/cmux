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

    /// cmux#47638: a composer Cloud send ('1+1') failed at "Set up a Cloud machine" with "Couldn't move the chat. the
    /// machine is not running; start it first". The start's link was up, but the machine's record did not run (a click's
    /// connect starts a paused machine and answers first; an idle pause can land as it comes up), and the Cloud API's exec
    /// refuses such a machine (`vm_not_running`). The route check, the start's first exec, now starts or resumes the
    /// machine and reads again; the chat starts with no update.
    @Test func aStartWhoseMachineDoesNotRunYetStartsItAndGoesOn() async throws {
        let machine = StoppedMachine(report: Self.unrouted(variables: ["CLAUDE_CODE_OAUTH_TOKEN"]))
        let updated = UpdateCount()
        try await CloudMachineRoute(exec: { _, _ in try await machine.exec() }, start: { await machine.start() })
            .prepare(family: "claude") { await updated.add() }
        #expect(await machine.starts == 1, "the start started the machine once")
        #expect(await machine.refusals == 1, "the route check read again once the machine ran")
        #expect(await updated.count == 0)
    }

    /// The same machine with no start to run (a caller that has none): the refusal is the route's, and nothing loops.
    /// A second refusal after a start, or a refusal of another kind, is thrown as it came, with no second start.
    @Test func aRefusalTheStartCannotLiftIsThrownAsItCame() async {
        let notRunning = CloudAPIError.http(status: 409, code: "vm_not_running", message: "the machine is not running; start it first")
        let forbidden = CloudAPIError.http(status: 403, code: "vm_forbidden", message: "this user may not use the team's machines")
        for (refusal, startsExpected) in [(notRunning, 1), (forbidden, 0)] {
            let starts = UpdateCount()
            let exec = CloudMachineRoute.startingWhenStopped({ _, _ in throw refusal }, start: { await starts.add() })
            await #expect(throws: refusal) { _ = try await exec("acp machine-auth", 1_000) }
            #expect(await starts.count == startsExpected)
        }
        let unwrapped = CloudMachineRoute.startingWhenStopped({ _, _ in throw notRunning }, start: nil)
        await #expect(throws: notRunning) { _ = try await unwrapped("acp machine-auth", 1_000) }
    }

    /// A machine its one start left not running (a resume that never landed) ends the start with Retry on that machine,
    /// with no second start (from claude-274-fork's review of the parallel fix).
    @Test func aMachineThatStaysStoppedEndsTheStartWithRetry() async {
        let starts = UpdateCount()
        let route = CloudMachineRoute(machineID: "vm-stopped", exec: { _, _ in
            throw CloudAPIError.http(status: 409, code: "vm_not_running", message: "the machine is not running; start it first")
        }, start: { await starts.add() })
        do {
            try await route.verify(family: "claude")
            Issue.record("a machine that does not run passed the route check")
        } catch let failure as CloudMoveFailure {
            #expect(failure.retry == .move(machineID: "vm-stopped"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await starts.count == 1)
    }

    /// A resume refused for the person's cancel, an approval still pending, a quota or a plan keeps its own error; a
    /// refusal a Retry can lift (a busy machine, a transport failure) does not.
    @Test func aRefusedResumeKeepsItsOwnReason() {
        #expect(CloudMachineRoute.keepsItsError(CancellationError()))
        for code in ["approval.pending", "cloud.quota.exceeded", "cloud.plan.required"] {
            #expect(CloudMachineRoute.keepsItsError(CloudAPIError.http(status: 409, code: code, message: nil)), "\(code)")
        }
        for code in ["cloud.machine.busy", "vm_unavailable"] {
            #expect(!CloudMachineRoute.keepsItsError(CloudAPIError.http(status: 409, code: code, message: nil)), "\(code)")
        }
        #expect(!CloudMachineRoute.keepsItsError(CloudAPIError.transport("offline")))
    }

    /// A start that could not start the machine (a quota, here) ends the route check with that error at once: no update
    /// of a machine that does not run first (the update waits up to 90 s), and no second start.
    @Test func aStartThatFailsEndsTheCheckWithItsErrorAndNoUpdate() async {
        let quota = CloudAPIError.http(status: 409, code: "cloud.quota.exceeded", message: "the team is at its machine limit")
        let starts = UpdateCount(), updated = UpdateCount()
        let route = CloudMachineRoute(machineID: "vm-quota", exec: { _, _ in
            throw CloudAPIError.http(status: 409, code: "vm_not_running", message: "the machine is not running; start it first")
        }, start: {
            await starts.add()
            throw quota
        })
        await #expect(throws: quota) { try await route.prepare(family: "claude") { await updated.add() } }
        #expect(await starts.count == 1)
        #expect(await updated.count == 0, "no update of a machine that does not run")
    }

    /// Only whole words of a code keep a refused resume's own error: `control_plane` or `planned` is no plan refusal.
    @Test func aCodeKeepsItsErrorOnlyByItsWholeWords() {
        for code in ["control_plane", "model_plane_provision", "planned"] {
            #expect(!CloudMachineRoute.keepsItsError(CloudAPIError.http(status: 409, code: code, message: nil)), "\(code)")
        }
        for code in ["cmux.cloud.plan_required", "cmux.cloud.approval_pending", "cloud.quota.vm_limit"] {
            #expect(CloudMachineRoute.keepsItsError(CloudAPIError.http(status: 409, code: code, message: nil)), "\(code)")
        }
    }

    /// 2026-11-21: the route check ran its command on the machine in every start (1.9 and 2.5 s of two starts on a warm
    /// spare). A report read ahead that says the chat starts is the check: no command runs, and no update.
    @Test func aReportReadAheadThatStartsTheChatRunsNoCommand() async throws {
        let ran = UpdateCount(), updated = UpdateCount(), now = Self.unrouted()
        let machine = CloudMachineRoute(exec: { _, _ in
            await ran.add()
            return CloudExecResult(exitCode: 0, stdout: now, stderr: "")
        })
        // The chat carries its connection, and the report says the agent service runs.
        try await machine.prepare(carriesConnection: true, family: "claude", ahead: Self.unrouted()) { await updated.add() }
        // The machine's Claude signs in by itself: a Claude chat with no connection starts on it.
        try await machine.prepare(family: "claude", ahead: Self.unrouted(variables: ["CLAUDE_CODE_OAUTH_TOKEN"])) { await updated.add() }
        #expect(await ran.count == 0)
        #expect(await updated.count == 0)
    }

    /// A report read ahead never refuses a start, and never starts one it cannot vouch for: one that says the chat does
    /// not start, one with its agent service down, or output that is no report is read again on the machine, whose
    /// answer now decides.
    @Test func aReportReadAheadThatDoesNotStartTheChatIsReadAgain() async throws {
        let now = Self.unrouted(variables: ["CLAUDE_CODE_OAUTH_TOKEN"])
        for ahead in [Self.unrouted(), Self.unrouted(variables: ["CLAUDE_CODE_OAUTH_TOKEN"], running: false), "", "no report\n"] {
            let ran = UpdateCount(), updated = UpdateCount()
            let machine = CloudMachineRoute(exec: { _, _ in
                await ran.add()
                return CloudExecResult(exitCode: 0, stdout: now, stderr: "")
            })
            // No connection of the chat's own: only the machine's sign-in, which it has now, starts the chat.
            try await machine.prepare(family: "claude", ahead: ahead) { await updated.add() }
            #expect(await ran.count == 1, "\(ahead.prefix(40))")
            #expect(await updated.count == 0)
        }
        // And a machine that now reports no route for a chat with no connection still ends with Set up Cloud.
        let machine = Self.machine(printing: Self.unrouted())
        await #expect(throws: CloudMachineRoute.NeedsConnection.self) {
            try await machine.prepare(family: "claude", ahead: Self.unrouted()) {}
        }
    }

    /// A machine that does not serve what the start needs is updated as before, whatever was read ahead.
    @Test func aReportReadAheadDoesNotSkipTheUpdateOfAMachineThatLacksACapability() async throws {
        let updated = UpdateCount()
        do {
            try await Self.machine(printing: Self.unrouted()).prepare(serves: { false }, carriesConnection: true, family: "codex", ahead: Self.unrouted()) { await updated.add() }
            Issue.record("the start went on with a connection the machine cannot take")
        } catch let failure as CloudMoveFailure {
            #expect(failure.message == CloudMachineRoute.tooOld)
        }
        #expect(await updated.count == 1)
    }

    /// The rule of a report read ahead: only a real report that says the chat starts; never the answers for no report.
    @Test func onlyARealReportThatStartsTheChatCountsAhead() {
        #expect(CloudMachineRoute.startsAhead(.ready, carriesConnection: false))
        #expect(CloudMachineRoute.startsAhead(.notEdge, carriesConnection: true))
        #expect(!CloudMachineRoute.startsAhead(.notEdge, carriesConnection: false))
        // A machine on software from before the report starts when read now (`starts`), but nothing read ahead vouches for it.
        for verdict in [CloudMachineRoute.Verdict.unsupported, .invalid, .noDaemon] {
            #expect(!CloudMachineRoute.startsAhead(verdict, carriesConnection: true), "\(verdict)")
        }
        let down = CloudMachineRoute.Agent(daemonRunning: false, routed: false, signsIn: true)
        #expect(!CloudMachineRoute.startsAhead(.holdsCredential, agent: down, carriesConnection: true))
    }

    /// What is kept from a read ahead: the output when it holds a report whose agent service runs, nothing when the
    /// machine printed none, its agent service is down (also on a machine that holds a login, which Rust names first),
    /// or the command could not run. It never starts the machine.
    @Test func theReportToKeepIsARealOneWhoseServiceRuns() async {
        let report = Self.unrouted()
        #expect(await Self.machine(printing: report).report() == report)
        let signedIn = Self.unrouted(variables: ["CLAUDE_CODE_OAUTH_TOKEN"])
        #expect(await Self.machine(printing: signedIn).report() == signedIn)
        #expect(await Self.machine(printing: "").report() == nil)
        #expect(await Self.machine(printing: "no report\n").report() == nil)
        #expect(await Self.machine(printing: Self.unrouted(running: false)).report() == nil)
        #expect(await Self.machine(printing: Self.unrouted(variables: ["CLAUDE_CODE_OAUTH_TOKEN"], running: false)).report() == nil)
        let machine = StoppedMachine(report: report)
        #expect(await CloudMachineRoute(exec: { _, _ in try await machine.exec() }, start: { await machine.start() }).report() == nil)
        #expect(await machine.starts == 0, "a read ahead never starts a machine")
    }

    /// A machine whose exec route refuses it as not running until it is started, then prints `report`.
    private actor StoppedMachine {
        let report: String
        private(set) var starts = 0, refusals = 0
        init(report: String) { self.report = report }
        func start() { starts += 1 }
        func exec() throws -> CloudExecResult {
            guard starts > 0 else {
                refusals += 1
                throw CloudAPIError.http(status: 409, code: "vm_not_running", message: "the machine is not running; start it first")
            }
            return CloudExecResult(exitCode: 0, stdout: report, stderr: "")
        }
    }

    @Test func anEndpointUpdatesAMachineThatLacksItsCapability() async throws {
        let updated = UpdateCount()
        do {
            try await Self.machine(printing: Self.unrouted()).prepare(serves: { false }, carriesConnection: true, family: "opencode", requiresCredentialCapability: true) { await updated.add() }
            Issue.record("the endpoint reached a machine without its capability")
        } catch let failure as CloudMoveFailure {
            #expect(failure.message == CloudMachineRoute.tooOld)
        }
        #expect(await updated.count == 1)
    }

    @Test func anEndpointCanLaunchWhenTheReportOnlyNamesOtherAgents() async throws {
        let updated = UpdateCount()
        try await Self.machine(printing: Self.unrouted(variables: ["CLAUDE_CODE_OAUTH_TOKEN"])).prepare(
            carriesConnection: true, family: "opencode", requiresCredentialCapability: true
        ) { await updated.add() }
        #expect(await updated.count == 0)
    }

    private actor UpdateCount {
        var count = 0
        func add() { count += 1 }
    }
}
