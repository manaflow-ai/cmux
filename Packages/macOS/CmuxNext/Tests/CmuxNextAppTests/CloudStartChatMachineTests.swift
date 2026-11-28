@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextCloudUI
@testable import CmuxNextDaemon
import Foundation
import Observation
import Testing

/// What stays in the App of a `cloud.startChat` send: the account and list checks, the folder it may
/// copy, and the machine's create. Which machine it takes, a retry's pin, its copy's folder and the
/// send's keys are cmux-tui's and tested there (`link/start_chat_cli/tests.rs`, on Linux).
@Suite
@MainActor
struct CloudStartChatMachineTests {
    private static let me = "user-leo"

    @Test func automaticPlacementPrefersAReadyClaudeMachineOnlyWhenReadinessUsesItsLogin() async throws {
        let session = CloudTestLink.session(id: "vm_ready", name: "dev")
        let setup = CloudSetup(read: { .init(personal: [], organization: []) })
        setup.claudeMachines = { [session.machine] }
        setup.readClaudeMachineLogin = { $0 == session.machineID }
        let start = try #require(AgentPaneCloudStart(params: ["task": "t", "harness": "claude", "key": UUID().uuidString]))

        let cases: [(Set<String>, CloudSetup.Choice)] = [
            (["claude"], .gateway(family: "claude")), ([], .claudeMachineLogin),
        ]
        for (families, expected) in cases {
            setup.gateway = { families }
            let readiness = await setup.plannerReadiness(for: start)
            #expect(readiness.choice == expected)
            let json = CloudStartChat.planRequest(key: start.key, account: [Self.me, "team-a"], workspace: nil,
                                                  user: Self.me, machines: [session], stored: [], readiness: readiness)
            let request = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            let candidates = try #require(request["machines"] as? [[String: Any]])
            #expect(candidates.first?["claude_ready"] as? Bool == true)
            #expect(request["machine"] == nil)
            #expect(request["claude_machine_login"] as? Bool == (expected == .claudeMachineLogin))
        }
    }

    @Test func aStatusReadPreservesTheVerifiedEnvironmentAcrossDerivedAndOmittedIDs() throws {
        let services = MachineIconTests.services(), cloud = services.cloud
        let session = MachineIconTests.cloudMachine(services, id: "vm-status-environment")
        let suite = "cloud-status-environment-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); session.disconnect() }
        cloud.move.ledger = defaults
        let selected = "env_0123456789abcdef01234567"
        var status = CloudMachine(id: session.machineID, status: .paused)
        status.environmentId = "denv_fedcba9876543210fedcba98"
        session.machine = cloud.setup.machineEnvironment(status, ensured: selected, account: cloud.account, defaults: defaults)

        cloud.reconcile([status], read: cloud.beginRecordRead())
        #expect(session.machine.environmentId == selected)
        cloud.apply(status, to: session, read: cloud.beginRecordRead(machineID: session.machineID))
        #expect(session.machine.environmentId == selected)

        status.environmentId = nil
        cloud.apply(status, to: session, read: cloud.beginRecordRead(machineID: session.machineID))
        #expect(CloudStartCore().matchesEnvironment(selected, machine: session.machine))
        #expect(session.machine.startChatPlanEntry(connected: false, chats: nil)["environment"] as? String == selected)
    }

    @Test func cloudAPIEnvironmentSurvivesThePinnedMachineFFIAndPlannerEntry() async throws {
        let selected = "env_0123456789abcdef01234567"
        let raw: JSONValue = .object(["id": .string("vm_test"), "environment_id": .string(selected)])
        let decoded = try #require(CloudMachine(next: raw))
        let withoutEnvironment = try #require(CloudMachine(next: .object(["id": .string("vm_test")])))
        let listed = decoded.listed(over: withoutEnvironment, connectedSinceRead: false)
        #expect(listed.environmentId == selected)
        #expect(listed.startChatPlanEntry(connected: false, chats: nil)["environment"] as? String == selected)
        #expect(!CloudStartCore().matchesEnvironment(selected, machine: withoutEnvironment))
        #expect(CloudStartCore().matchesEnvironment(nil, machine: withoutEnvironment))
        let other = "env_fedcba9876543210fedcba98"
        #expect(!CloudStartCore().matchesEnvironment(other, machine: listed))
        let setup = CloudSetup()
        setup.claudeMachines = { [withoutEnvironment] }
        setup.readClaudeMachineLogin = { _ in true }
        #expect(!setup.machineMatchesEnvironment(withoutEnvironment.id, environment: selected))
        #expect(await setup.readyClaudeMachines(machine: withoutEnvironment.id, environment: selected).isEmpty)
        #expect(await setup.readyClaudeMachines(environment: selected).isEmpty)
        setup.claudeMachines = { [listed] }
        #expect(!setup.machineMatchesEnvironment(listed.id, environment: other))
    }

    @Test(arguments: [false, true])
    func aProvisionedPlanCanStartThroughThePinnedFFI(withEnvironment: Bool) async throws {
        let selected = "env_0123456789abcdef01234567"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("fixture")
        let proof = withEnvironment ? #", "selected_environment":"\#(selected)""# : ""
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"ok":true,"machine":"vm_test","create_key":"create","tab_key":"tab","ensured":{"created":true\(proof)}}'
        """
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)

        let plan = try CloudMoveStrings.checked(await CloudMoveCLI(binary: binary).startChatPlan(request: "{}"))
        let record = try #require(CloudMachine(next: .object(["id": .string("vm_test")])))
        #expect(plan.machine == record.id)
        #expect(plan.ensuredEnvironment == (withEnvironment ? selected : nil))
        #expect(CloudStartCore().matchesEnvironment(selected, machine: record, ensured: plan.ensuredEnvironment) == withEnvironment)
        if withEnvironment {
            let derived = try #require(CloudMachine(next: .object([
                "id": .string("vm_test"), "environment_id": .string("denv_fedcba9876543210fedcba98"),
            ])))
            #expect(CloudStartCore().matchesEnvironment(selected, machine: derived, ensured: plan.ensuredEnvironment))
            let suite = "cloud-start-environment-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let setup = CloudSetup(), account: [String?] = [Self.me, nil]
            let provisioned = setup.machineEnvironment(derived, ensured: plan.ensuredEnvironment, account: account, defaults: defaults)
            #expect(provisioned.environmentId == selected)
            _ = setup.machineEnvironment(provisioned, account: account, defaults: defaults)
            #expect(setup.machineEnvironment(derived, account: account, defaults: defaults).environmentId == selected)
        }
    }

    @Test func aRetryUsesTheDurablePaneAfterReorderingAndHandleReuse() throws {
        let store = DaemonStore()
        func tree(_ reordered: Bool) -> DaemonTree {
            let target = PaneSnapshot(id: PaneID(rawValue: reordered ? 9 : 1), resourceID: ResourceID(rawValue: "pane_target"))
            let other = PaneSnapshot(id: 1, resourceID: ResourceID(rawValue: "pane_other"))
            let screen = ScreenSnapshot(id: 1, layout: .leaf(target.id), panes: reordered ? [other, target] : [target])
            return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: "ws-key"), name: "chat", screens: [screen])])
        }
        store.apply(snapshot: tree(false))
        #expect(CloudMachineWorkspace.targetAnchor("pane_target", in: store)?.pane.handle == PaneID(rawValue: 1))
        store.apply(snapshot: tree(true))
        #expect(CloudMachineWorkspace.targetAnchor("pane_target", in: store)?.pane.handle == PaneID(rawValue: 9))
        #expect(CloudMachineWorkspace.targetAnchor("pane_missing", in: store) == nil)
        #expect(CloudMachineWorkspace.targetAnchor("pane:1", in: store) == nil)
    }

    /// The start's checks are Rust's (cmux-cloud-start-core `start`, with their cases): the refusal, the
    /// account a send began in and its list, and the folder it may copy. This checks only that the app
    /// reaches them and throws or answers in its own terms.
    @Test func theStartsChecksComeFromTheRustRules() throws {
        let teamA: [String?] = [Self.me, "team-a"], teamB: [String?] = [Self.me, "team-b"]
        #expect(CloudStartCore().refusal(cloudDisabled: false, signedIn: true) == nil)
        #expect(CloudStartCore().refusal(cloudDisabled: false, signedIn: false) == "not_signed_in")
        #expect(CloudStartCore().refusal(cloudDisabled: true, signedIn: true) == "cloud_disabled")
        #expect(CloudStartCore().accountText([Self.me, nil]) == "user-leo/")
        try CloudStartChat.checkAccount(teamA, now: teamA, listCurrent: true)
        #expect(throws: CloudMove.Failure.self) { try CloudStartChat.checkAccount(teamA, now: teamB, listCurrent: true) }
        #expect(throws: CloudMove.Failure.self) { try CloudStartChat.checkAccount(teamA, now: teamA, listCurrent: false) }
        let folder = try #require(CloudMoveFolder(chat: "/Users/me/src/paint"))
        var start = try #require(AgentPaneCloudStart(params: ["task": "t", "cwd": "/Users/me/src/paint", "key": UUID().uuidString]))
        #expect(!start.uploads(folder))
        start.uploadRoot = folder.root
        #expect(start.uploads(folder))
        let tabs = try #require(AgentPaneCloudStart(params: ["task": "t", "key": UUID().uuidString]))
        #expect(!tabs.uploads(try #require(CloudMoveFolder(chat: "/Users")), home: "/Users/me"))
        #expect(try #require(CloudMoveFolder(chat: "/")).isTooBroad)
        #expect(try #require(CloudMoveFolder(chat: NSHomeDirectory())).isTooBroad)
    }

    /// Proof run on a fresh staging machine (2026-11-01): its image's older cmux-tui refused the
    /// copy with `machine_outdated` and the first send failed with "Update the machine". That answer
    /// (about the machine, never this Mac's side) updates the machine and copies again; nothing else does.
    @Test func onlyTheMachinesOutdatedRefusalUpdatesItBeforeCopyingAgain() async throws {
        let outdated = CloudOutdatedMachine.code
        #expect(CloudMoveStrings.outdatedCode == outdated)
        let read = { (answer: CloudMoveCLI.Answer) -> (ok: Bool, errorCode: String?, side: String?) in (answer.ok, answer.errorCode, answer.side) }
        for (first, updates) in [(CloudMoveCLI.Answer(ok: false, errorCode: outdated), true),
                                 (.init(ok: false, errorCode: outdated, side: "target"), true),
                                 (.init(ok: false, errorCode: outdated, side: "source"), false),
                                 (.init(ok: false, errorCode: "sync_failed"), false), (.init(ok: true), false)] {
            for updated in [true, false] {
                let link = Link()
                var sockets: [String] = [], asked = 0
                let answer = try await CloudOutdatedMachine.copy(socket: { link.socket }, link: { link.key }, notConnected: CancellationError(),
                                                                 relink: .seconds(5)) { (socket: String) async throws -> CloudMoveCLI.Answer in
                    sockets.append(socket)
                    return sockets.count == 1 ? first : CloudMoveCLI.Answer(ok: true)
                } answer: { read($0) } update: {
                    asked += 1
                    link.restart()
                    return updated
                }
                #expect(asked == (updates ? 1 : 0))
                #expect(sockets == (updates && updated ? ["link-1.sock", "link-2.sock"] : ["link-1.sock"]))
                #expect(answer == (updates && updated ? CloudMoveCLI.Answer(ok: true) : first))
            }
        }
    }

    /// Capture at ff3f8c9b (2026-11-01): the update restarted the machine's daemon and its link came back on a new
    /// socket a moment after the update returned. The second copy waits for the new link instead of failing with
    /// "cannot connect to …/cmux-link-….sock: No such file or directory", and nothing copies while not connected.
    @Test func theCopyAfterAnUpdateWaitsForTheMachinesNewLink() async throws {
        let link = Link(), outdated = CloudMoveCLI.Answer(ok: false, errorCode: CloudOutdatedMachine.code)
        var sockets: [String] = []
        let answer = try await CloudOutdatedMachine.copy(socket: { link.socket }, link: { link.key }, notConnected: CancellationError(),
                                                         relink: .seconds(30)) { (socket: String) async throws -> CloudMoveCLI.Answer in
            sockets.append(socket)
            return sockets.count == 1 ? outdated : CloudMoveCLI.Answer(ok: true)
        } answer: { ($0.ok, $0.errorCode, $0.side) } update: {
            link.drop()
            Task { @MainActor in link.restart() }
            return true
        }
        #expect(sockets == ["link-1.sock", "link-2.sock"])
        #expect(answer == CloudMoveCLI.Answer(ok: true))
        let gone = Link()
        gone.drop()
        await #expect(throws: CancellationError.self) {
            _ = try await CloudOutdatedMachine.copy(socket: { gone.socket }, link: { gone.key }, notConnected: CancellationError()) { (_: String) async throws in
                Issue.record("copied while not connected")
                return CloudMoveCLI.Answer(ok: true)
            } answer: { ($0.ok, $0.errorCode, $0.side) } update: { true }
        }
    }

    /// A machine's daemon link as the copy sees it: its socket and handshake key, observable, both
    /// gone while the daemon restarts.
    @MainActor @Observable fileprivate final class Link {
        private(set) var generation: Int? = 1
        var socket: String? { generation.map { "link-\($0).sock" } }
        var key: String? { generation.map { "key-\($0)" } }
        private var last = 1
        func drop() { generation = nil }
        func restart() { last += 1; generation = last }
    }

    /// The plan reads the send under its account and Mac workspace, only the machines the account's list
    /// named, and the ones made since (kept for a pin, never picked).
    /// Router review at f766845: a machine the server destroyed may stay in the store after the list dropped it. It is
    /// never sent as made since, so a workspace or send pinned to it moves on instead of failing to connect.
    @Test func aGoneMachineInTheStoreIsNeverKeptForAPin() {
        let machines = [CloudMachine(id: "vm-listed"), CloudMachine(id: "vm-new", status: .provisioning),
                        CloudMachine(id: "vm-destroyed", status: .destroyed), CloudMachine(id: "vm-failed", status: .failed),
                        CloudMachine(id: "vm-deleting", status: .deleting)]
        #expect(machines.keptForPin(listed: ["vm-listed"]) == ["vm-new"])
    }

    /// A listed machine's plan entry: its id, title, shown status and link, the known slug and pause reason, and its
    /// chat count only when connected (a disconnected machine's entry has no `chats` key).
    @Test func aListedMachinesPlanEntryNamesWhatThePickReads() {
        let machine = CloudMachine(id: "vm-a", status: .paused, displayName: "Chats", slug: "kind-aqua", pauseReason: .idle)
        let connected = machine.startChatPlanEntry(connected: true, chats: 2)
        #expect(connected["id"] as? String == "vm-a" && connected["title"] as? String == "Chats")
        #expect(connected["status"] as? String == "paused" && connected["connected"] as? Bool == true)
        #expect(connected["slug"] as? String == "kind-aqua" && connected["pause_reason"] as? String == "idle")
        #expect(connected["chats"] as? Int == 2 && connected["created_by"] == nil)
        let away = CloudMachine(id: "vm-b").startChatPlanEntry(connected: false, chats: nil)
        #expect(away["connected"] as? Bool == false && away["chats"] == nil && away["slug"] == nil && away["pause_reason"] == nil)
    }

    /// Leo, 2026-11-06: the default flow, with no environment step, keeps a project's dependencies warm on
    /// production too: a personal send there asks the platform it signed in to, never the CLI's development default.
    @Test func aPersonalSendGetsTheSetUpProjectMachineOnProductionWhenItsPlatformIsKnown() {
        let production = URL(string: "https://cmux-platform.debussy.workers.dev")
        #expect(CloudStartCore().ensuresProject(account: [Self.me, nil], platform: production, production: true))
        #expect(!CloudStartCore().ensuresProject(account: [Self.me, nil], platform: nil, production: true))
        #expect(CloudStartCore().ensuresProject(account: [Self.me, nil], platform: nil, production: false))
        #expect(!CloudStartCore().ensuresProject(account: [Self.me, "team-a"], platform: production, production: true))
    }

    /// Router review at 6beb0f2: with no `cwd` the tab's own folder is copied, and its `.git` file
    /// can name a repository elsewhere (a linked worktree): that send is refused, like one with `cwd`.
    @Test func aTabsFolderWhoseGitFolderIsElsewhereIsNeverCopied() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("cn-start-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let project = scratch.appendingPathComponent("project"), external = scratch.appendingPathComponent("repo.git")
        let worktree = external.appendingPathComponent("worktrees/project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "../..\n".write(to: worktree.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        try "gitdir: \(worktree.path)\n".write(to: project.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        let tabs = try #require(AgentPaneCloudStart(params: ["task": "t", "key": UUID().uuidString]))
        let folder = try #require(CloudMoveFolder(chat: project.path))
        #expect(folder.subpath.isEmpty)
        #expect(!tabs.uploads(folder, home: "/Users/nobody"))
        // A working copy whose git folder is its own `.git` folder is copied.
        try FileManager.default.removeItem(at: project.appendingPathComponent(".git"))
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        #expect(tabs.uploads(try #require(CloudMoveFolder(chat: project.path)), home: "/Users/nobody"))
    }

    /// The create's key is the plan's, so a retry after a lost create answer never makes a second VM;
    /// and its team is the send's, fixed for every try, so a team switch during a slow create never
    /// makes the machine in the other team (router review at 2208632).
    @Test func aNewMachineIsCreatedUnderThePlansKeyInTheSendsTeam() async throws {
        let request = CloudMachineRequest(startChatKey: "cloud-start-chat-k", sizedFor: nil, team: "team-a")
        #expect(request.idempotencyKey == "cloud-start-chat-k")
        #expect(request.team == "team-a")
        #expect(!request.wasSent)
    }

    /// A signed-out first send keeps its stable refusal code for callers, but the
    /// card must tell the person how to sign in instead of displaying `not_signed_in`.
    @Test func aSignedOutFirstSendCarriesActionableRecoveryCopy() {
        #expect(CloudStrings.startRefusal("not_signed_in") == CloudStrings.signInFirst)
        #expect(CloudStrings.startRefusal("cloud_disabled") == "cloud_disabled")
    }
}
