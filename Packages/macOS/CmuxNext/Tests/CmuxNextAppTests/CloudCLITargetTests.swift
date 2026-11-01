import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextControl
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Cloud machine actions from the CLI, MCP, a script, a page or another client
/// act only on the machine they name (`--target machine:<id>`). Before, a run
/// with no target fell back to the machine the person's window showed, else the
/// only machine, so an agent's `cloud kill-machine --confirm true` could kill
/// the machine the person was looking at. A person's own gesture keeps the
/// fallback. A non-person run also gets its answer back as `action.run`'s
/// `result` (`cloud new-machine` answers with the new machine's id).
@MainActor @Suite(.serialized)
struct CloudCLITargetTests {
    static func fixture() -> (services: AppServices, context: AppActionContext, session: CloudMachineSession) {
        let services = MachineIconTests.services()
        let session = MachineIconTests.cloudMachine(services, id: "vm-cli-\(UUID().uuidString.prefix(8))")
        return (services, AppActionContext(services: services), session)
    }

    @Test(arguments: [ActionOrigin.cli, .mcp, .script, .remote, .page])
    func aRunThatIsNotThePersonsNeedsAMachineTarget(origin: ActionOrigin) {
        let f = Self.fixture()
        #expect(f.services.machines.cloud.count == 1, "the only machine is the old fallback")
        #expect(throws: ActionFailure(message: CloudStrings.noMachine)) {
            try CloudHandlers.machine(ActionInvocation(origin: origin), f.context)
        }
    }

    @Test(arguments: [ActionOrigin.cli, .mcp, .script, .remote, .page])
    func aRunThatNamesItsMachineActsOnIt(origin: ActionOrigin) throws {
        let f = Self.fixture()
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .machine, id: f.session.machineID), origin: origin)
        #expect(try CloudHandlers.machine(invocation, f.context) === f.session)
    }

    @Test func aRunNamingAMachineThatIsNotThereIsNotFound() {
        let f = Self.fixture()
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .machine, id: "vm-gone"), origin: .cli)
        do {
            _ = try CloudHandlers.machine(invocation, f.context)
            Issue.record("a missing machine resolved")
        } catch let failure as ActionFailure {
            #expect(failure.isNotFound)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func thePersonsGestureKeepsTheOnlyMachineFallback() throws {
        let f = Self.fixture()
        #expect(try CloudHandlers.machine(ActionInvocation(origin: .user), f.context) === f.session)
    }

    @Test func newCloudWorkspaceKeepsTheFallbackForAnyCaller() throws {
        let f = Self.fixture()
        #expect(try CloudHandlers.machine(ActionInvocation(origin: .cli), f.context, fallsBack: true) === f.session)
    }

    // MARK: Results for non-person runs

    @Test func aCLIAnswerComesBackAsTheRunsResult() async throws {
        let f = Self.fixture()
        let run = f.services.registry.capturingRun {
            CloudHandlers.answer("test answer", ActionInvocation(origin: .cli), f.context) {
                CloudAnswer(title: "Title", text: "hello", fields: ["count": .int(2)])
            }
        }
        let task = try #require(run.results.first)
        guard case .success(let fields) = await task.value else {
            Issue.record("the answer failed")
            return
        }
        #expect(fields["text"] == .string("hello"))
        #expect(fields["count"] == .int(2))
    }

    @Test func aRefusalInTheWorkReachesTheCallerAsOne() async throws {
        let f = Self.fixture()
        let run = f.services.registry.capturingRun {
            CloudHandlers.result("test refusal", f.context) { throw ActionFailure(message: CloudStrings.notConnected) }
        }
        let task = try #require(run.results.first)
        guard case .failure(let failure) = await task.value else {
            Issue.record("the refusal succeeded")
            return
        }
        #expect(failure.refusal == .unavailable)
        #expect(failure.message == CloudStrings.notConnected)
    }

    /// A nested run is built with the default user origin; the run it sits in
    /// (``ActionRunScope``) decides, so a composite action started from the CLI
    /// gets no fallback either.
    @Test func aNestedRunInsideACLIRunNeedsAMachineTarget() {
        let f = Self.fixture()
        ActionRunScope.$current.withValue(ActionRunScope(origin: .cli, allowsViewChange: false)) {
            #expect(throws: ActionFailure(message: CloudStrings.noMachine)) {
                try CloudHandlers.machine(ActionInvocation(), f.context)
            }
        }
    }

    /// Slow work (a snapshot can take minutes) answers `pending` once
    /// `pendingAfter` passes, well inside `action.run`'s 40 s result deadline,
    /// and keeps running; it never holds the answer until the work ends.
    @Test(.timeLimit(.minutes(1)))
    func slowWorkAnswersPendingWhenItsWaitEnds() async throws {
        let f = Self.fixture()
        let clock = ContinuousClock()
        let run = f.services.registry.capturingRun {
            CloudHandlers.result("slow snapshot", f.context, pendingAfter: .milliseconds(100), pending: ["machine_id": .string("vm-slow")]) {
                // wakeup-allow: a test's stand-in for a snapshot that takes longer than the answer's wait
                try await Task.sleep(for: .seconds(8))
                return ["snapshot_id": .string("late")]
            }
        }
        let task = try #require(run.results.first)
        let started = clock.now
        guard case .success(let fields) = await task.value else {
            Issue.record("slow work failed")
            return
        }
        #expect(fields["pending"] == .bool(true))
        #expect(fields["machine_id"] == .string("vm-slow"))
        #expect(fields["snapshot_id"] == nil)
        #expect(started.duration(to: clock.now) < .seconds(5), "the answer waited for the work")
    }

    @Test func quickWorkAnswersWithItsResultBeforeTheWaitEnds() async throws {
        let f = Self.fixture()
        let run = f.services.registry.capturingRun {
            CloudHandlers.result("quick snapshot", f.context, pendingAfter: .seconds(20)) { ["snapshot_id": .string("snap-1")] }
        }
        let task = try #require(run.results.first)
        guard case .success(let fields) = await task.value else {
            Issue.record("quick work failed")
            return
        }
        #expect(fields["snapshot_id"] == .string("snap-1"))
        #expect(fields["pending"] == nil)
    }

    @Test func newMachineAnswersWithTheMachineOnceTheServerReturnsIt() async throws {
        let f = Self.fixture()
        let creations = f.services.cloud.creations
        let creation = creations.begin(window: nil)
        let run = f.services.registry.capturingRun { CloudHandlers.reportCreatedMachine(creation, f.context) }
        let task = try #require(run.results.first)
        creation.attach(f.session)
        guard case .success(let fields) = await task.value else {
            Issue.record("the create failed")
            return
        }
        #expect(fields["machine_id"] == .string(f.session.machineID))
        #expect(fields["target"] == .string("machine:\(f.session.machineID)"))
        #expect(fields["pending"] == nil)
        creations.remove(creation)
    }

    @Test func aSlowCreateAnswersPendingInsteadOfTimingOut() async throws {
        let f = Self.fixture()
        let creations = f.services.cloud.creations
        let creation = creations.begin(window: nil)
        let run = f.services.registry.capturingRun { CloudHandlers.reportCreatedMachine(creation, f.context, wait: .milliseconds(50)) }
        let task = try #require(run.results.first)
        guard case .success(let fields) = await task.value else {
            Issue.record("a slow create failed")
            return
        }
        #expect(fields["pending"] == .bool(true))
        #expect(fields["creation_id"] == .string(creation.id.uuidString.lowercased()))
        creations.remove(creation)
    }

    @Test func aDeclinedCreateIsRefused() async throws {
        let f = Self.fixture()
        let creations = f.services.cloud.creations
        let creation = creations.begin(window: nil)
        let run = f.services.registry.capturingRun { CloudHandlers.reportCreatedMachine(creation, f.context) }
        let task = try #require(run.results.first)
        creations.remove(creation)
        guard case .failure(let failure) = await task.value else {
            Issue.record("a declined create succeeded")
            return
        }
        #expect(failure.message == CloudStrings.createDeclined)
    }

    @Test func aFailedCreateSaysWhy() async throws {
        let f = Self.fixture()
        let creations = f.services.cloud.creations
        let creation = creations.begin(window: nil)
        let run = f.services.registry.capturingRun { CloudHandlers.reportCreatedMachine(creation, f.context) }
        let task = try #require(run.results.first)
        creation.fail(ActionFailure(message: "quota"))
        guard case .failure(let failure) = await task.value else {
            Issue.record("a failed create succeeded")
            return
        }
        #expect(failure.message.contains("quota"))
        creations.remove(creation)
    }

    // MARK: Cloud Diagnostics' copied details

    /// A daemon handshake with every `identify` field set, each to a value no other field has.
    static func fullIdentity() -> DaemonIdentity {
        var identity = DaemonIdentity(
            app: "cmux-tui", version: "0.9.1", buildCommit: "3412812eae76aaaabbbb", ghosttyCommit: "9c1d2e3f4a5b",
            protocolVersion: 12, capabilities: ["cap-alpha", "cap-beta"], session: "vm-session-name", pid: 4242,
            registryID: "6f1c0b8e-reg-0001", machineResourceID: "res-machine-1", sessionResourceID: "res-session-1",
            machinePlatform: MachineCatalogPlatform(os: "linux", arch: "arm64"), machineCapabilities: ["mcap-one"],
            machineName: "vm-host-name", generation: "gen-7", workspaceRevision: 31, lifecycleReady: false)
        identity.launchSnapshotPath = "/private/tmp/cn-launch-snapshot.json"
        identity.buildID = "3412812eae76aaaabbbb-dirty.12345678"
        identity.cliPath = "/Applications/cmux NEXT.app/Contents/Resources/bin/cmux-tui"
        return identity
    }

    /// Each `identify` field under its wire name, as `JSONSerialization` reads the copied details.
    static var fullIdentityWire: [String: Any] { [
        "app": "cmux-tui", "version": "0.9.1", "build_commit": "3412812eae76aaaabbbb", "ghostty_commit": "9c1d2e3f4a5b",
        "build_id": "3412812eae76aaaabbbb-dirty.12345678",
        "protocol": 12, "capabilities": ["cap-alpha", "cap-beta"], "session": "vm-session-name", "pid": 4242,
        "registry_id": "6f1c0b8e-reg-0001", "machine_id": "res-machine-1", "session_resource_id": "res-session-1",
        "machine_platform": ["os": "linux", "arch": "arm64"], "machine_capabilities": ["mcap-one"],
        "machine_name": "vm-host-name", "generation": "gen-7", "workspace_revision": 31, "lifecycle_ready": false,
        "launch_snapshot_path": "/private/tmp/cn-launch-snapshot.json",
        "cli_path": "/Applications/cmux NEXT.app/Contents/Resources/bin/cmux-tui",
    ] }

    static func json(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// #23109 made the toast one line and its Copy details JSON, and the JSON lost what the old text
    /// dump printed from the daemon's handshake: the ghostty commit, the whole capability list, the
    /// daemon's pid, registry id and generation. Every field reaches the copied details again.
    @Test func theCopiedDetailsCarryEveryFieldOfTheDaemonsHandshake() async throws {
        let f = Self.fixture()
        f.session.daemon.store.connectionState = .connected(Self.fullIdentity())
        let report = await CloudHandlers.diagnostics(f.context)
        let details = try Self.json(report.details)
        let machines = try #require(details["machines"] as? [[String: Any]])
        let row = try #require(machines.first { $0["id"] as? String == f.session.machineID })
        let identity = try #require(row["daemon_identity"] as? [String: Any])
        #expect(NSDictionary(dictionary: identity).isEqual(to: Self.fullIdentityWire))
        #expect(row["daemon_reason"] is NSNull)
        #expect(row["link_pid"] as? String != nil)
        // The machine row of `cloud.machines` is still all there too.
        for key in ["title", "status", "api_status", "stage", "stage_detail", "daemon", "session_id", "session", "protocol",
                    "daemon_version", "daemon_commit", "compatibility", "missing_required", "missing_features", "workspaces"] {
            #expect(row[key] != nil, "the details dropped \(key)")
        }
        #expect(report.details.contains("9c1d2e3f4a5b"), "the ghostty commit is in the copied text")
    }

    /// A Cloud machine daemon's handshake with every required capability and `extra`.
    static func cloudHandshake(_ store: DaemonStore, extra: [String]) throws {
        let list = (DaemonCapability.required + extra).map { "\"\($0)\"" }.joined(separator: ",")
        let json = #"{"app":"cmux-tui","protocol":12,"session":"cloud","generation":"g1","capabilities":["# + list + "]}"
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
    }

    /// A Cloud machine whose daemon does not serve `fs-v1` (no model plane identity on a fresh
    /// VM) cannot take Move to Cloud's or a Cloud chat's first sync: its row says so, and its
    /// compatibility is not `current`, before any sync fails on `fs.unavailable`.
    @Test func aCloudMachineWithoutFileOpsIsReportedBeforeTheSync() throws {
        let unknown = Self.fixture()
        #expect(AppControl.cloudMachineRow(unknown.session, unknown.services.machines)["file_ops"] == .null,
                "unknown before the daemon answers")

        let without = Self.fixture()
        try Self.cloudHandshake(without.session.daemon.store, extra: DaemonCapability.optional.filter { $0 != "fs-v1" })
        let row = AppControl.cloudMachineRow(without.session, without.services.machines)
        #expect(row["file_ops"] == .bool(false))
        #expect(row["compatibility"] == .string("limited"))
        #expect(row["missing_features"]?.arrayValue?.contains(.string("fs-v1")) == true)

        let with = Self.fixture()
        try Self.cloudHandshake(with.session.daemon.store, extra: DaemonCapability.optional + ["fs-v1"])
        let served = AppControl.cloudMachineRow(with.session, with.services.machines)
        #expect(served["file_ops"] == .bool(true))
        #expect(served["missing_features"]?.arrayValue?.contains(.string("fs-v1")) != true)
    }

    /// A field added to `identify` must reach the details too: every stored property of
    /// `DaemonIdentity` (but the lookup set it derives) has a wire key in the fixture above.
    @Test func everyStoredFieldOfTheHandshakeIsInTheDetails() {
        let stored = Mirror(reflecting: Self.fullIdentity()).children.compactMap(\.label).filter { $0 != "capabilitySet" }
        #expect(stored.count == Self.fullIdentityWire.count, "DaemonIdentity has \(stored), the details \(Self.fullIdentityWire.keys.sorted())")
        #expect(CloudDiagnosticsReport.identityFields(Self.fullIdentity()).count == Self.fullIdentityWire.count)
    }

    /// A machine whose link dropped keeps the last handshake in its details, and says why it dropped.
    @Test func aDroppedLinkKeepsTheLastHandshakeAndItsReason() {
        let details = CloudDiagnosticsReport.daemonDetails(.disconnected("socket closed"), last: Self.fullIdentity())
        #expect(details["daemon_reason"] == .string("socket closed"))
        #expect(details["daemon_identity"]?["ghostty_commit"] == .string("9c1d2e3f4a5b"))
        #expect(details["daemon_identity"]?["pid"] == .number(4242))
        let never = CloudDiagnosticsReport.daemonDetails(.connecting, last: nil)
        #expect(never["daemon_identity"] == .null)
        #expect(never["daemon_reason"] == .null)
    }

    /// The account half: the team's id and, from the team list the app already holds, its name.
    @Test func theCopiedDetailsCarryEveryAccountField() throws {
        let account = CloudDiagnosticsReport.Account(
            backend: "https://cloud.example.test", backendKind: "production", signedIn: true, email: "leo@example.test",
            teamID: "0f8fad5b-d9cb-469f-a165-70867728950e", teamName: "Manaflow", unavailable: "maintenance", lastError: "quota")
        let details = try Self.json(CloudDiagnosticsReport.details(account, machines: []))
        let expected: [String: Any] = [
            "backend": "https://cloud.example.test", "backend_kind": "production", "signed_in": true, "email": "leo@example.test",
            "team_id": "0f8fad5b-d9cb-469f-a165-70867728950e", "team_name": "Manaflow", "unavailable": "maintenance",
            "last_error": "quota", "machines": [Any](),
        ]
        #expect(NSDictionary(dictionary: details).isEqual(to: expected))
    }

    @Test func theLiveDetailsHaveTheTeamNameKey() async throws {
        let f = Self.fixture()
        let details = try Self.json(await CloudHandlers.diagnostics(f.context).details)
        for key in ["backend", "backend_kind", "signed_in", "email", "team_id", "team_name", "unavailable", "last_error", "machines"] {
            #expect(details[key] != nil, "the details dropped \(key)")
        }
    }

    /// The visible line names the team by its name, never its UUID, when it has no email to show.
    @Test func theVisibleLineNamesTheTeamNotItsUUID() {
        let uuid = "0f8fad5b-d9cb-469f-a165-70867728950e"
        var account = CloudDiagnosticsReport.Account(backend: "", backendKind: "", signedIn: true, email: nil, teamID: uuid, teamName: "Manaflow")
        #expect(CloudDiagnosticsReport.accountLabel(account) == "Manaflow")
        account.email = "leo@example.test"
        #expect(CloudDiagnosticsReport.accountLabel(account) == "leo@example.test")
        account.email = nil
        account.teamName = nil
        #expect(CloudDiagnosticsReport.accountLabel(account) == uuid, "the UUID stands in only when the team list has no name")
    }
}
