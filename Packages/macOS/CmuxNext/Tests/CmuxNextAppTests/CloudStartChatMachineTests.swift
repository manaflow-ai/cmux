@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCloud
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

    /// Router review at 2a315af: a team switch keeps the user signed in and the previous team's
    /// machines in the store until the new list lands. A send is kept under the account it was sent
    /// in, and copies nothing while the account changed or its list is not current.
    @Test func aSendIsKeptUnderTheAccountItBeganInAndChecksItAtEveryStep() throws {
        let teamA: [String?] = [Self.me, "team-a"], teamB: [String?] = [Self.me, "team-b"]
        #expect(CloudStartChat.accountText(teamA) == "user-leo/team-a")
        #expect(CloudStartChat.accountText(teamA) != CloudStartChat.accountText(teamB))
        #expect(CloudStartChat.accountText([Self.me, nil]) == "user-leo/")
        try CloudStartChat.checkAccount(teamA, now: teamA, listCurrent: true)
        #expect(throws: CloudMove.Failure.self) { try CloudStartChat.checkAccount(teamA, now: teamB, listCurrent: true) }
        #expect(throws: CloudMove.Failure.self) { try CloudStartChat.checkAccount(teamA, now: teamA, listCurrent: false) }
        #expect(throws: CloudMove.Failure.self) { try CloudStartChat.checkAccount(teamA, now: [nil, nil], listCurrent: true) }
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
    @MainActor @Observable private final class Link {
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

    @Test func thePlanRequestCarriesTheSendItsAccountWorkspaceAndTheListedMachines() throws {
        let text = CloudStartChat.planRequest(key: "K", account: [Self.me, "team-a"], workspace: "ws-1", user: Self.me, machines: [],
                                              stored: ["vm-new"])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["key"] as? String == "K")
        #expect(object["account"] as? String == "user-leo/team-a")
        #expect(object["workspace"] as? String == "ws-1")
        #expect(object["user"] as? String == Self.me)
        #expect(object["loaded"] as? Bool == true)
        #expect((object["machines"] as? [Any])?.isEmpty == true)
        #expect(object["stored"] as? [String] == ["vm-new"])
        let signedOut = CloudStartChat.planRequest(key: "K", account: [nil, nil], workspace: nil, user: nil, machines: [], stored: [])
        let unsigned = try #require(try JSONSerialization.jsonObject(with: Data(signedOut.utf8)) as? [String: Any])
        #expect(unsigned["user"] == nil)
        #expect(unsigned["workspace"] == nil)
        #expect(unsigned["credential_on_stdin"] as? Bool == false)
        // Zero-setup hot start: the folder, the chosen environment and that the token is on stdin.
        let hot = CloudStartChat.planRequest(key: "K", account: [Self.me, nil], workspace: nil, user: Self.me, machines: [],
                                             local: "/Users/me/src/paint", stored: [], environment: "env_0123456789abcdef01234567", access: true)
        let ensure = try #require(try JSONSerialization.jsonObject(with: Data(hot.utf8)) as? [String: Any])
        #expect(ensure["local"] as? String == "/Users/me/src/paint")
        #expect(ensure["environment"] as? String == "env_0123456789abcdef01234567")
        #expect(ensure["credential_on_stdin"] as? Bool == true)
    }

    /// A folder the page named is copied only as the pane checked it.
    @Test func aPageNamedFolderIsCopiedOnlyAsItsCheckedUploadRoot() throws {
        let folder = try #require(CloudMoveFolder(chat: "/Users/me/src/paint"))
        var start = try #require(AgentPaneCloudStart(params: ["task": "t", "cwd": "/Users/me/src/paint", "key": UUID().uuidString]))
        #expect(!start.uploads(folder))
        start.uploadRoot = folder.root
        #expect(start.uploads(folder))
        start.uploadRoot = "/Users/me/src/paint/sub"
        #expect(!start.uploads(folder))
        // The tab's own folder (no `cwd`): only that folder itself, never a working copy above it.
        let tabs = try #require(AgentPaneCloudStart(params: ["task": "t", "key": UUID().uuidString]))
        #expect(tabs.uploads(folder))
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("cn-start-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: repo) }
        let project = repo.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let inRepo = try #require(CloudMoveFolder(chat: project.path))
        #expect(!inRepo.subpath.isEmpty)
        #expect(!tabs.uploads(inRepo))
        let atRoot = try #require(CloudMoveFolder(chat: repo.path))
        #expect(tabs.uploads(atRoot))
        // Never the home folder or a folder above it (a tab in /Users), whatever `isTooBroad` says.
        let users = try #require(CloudMoveFolder(chat: "/Users"))
        #expect(!tabs.uploads(users, home: "/Users/me"))
        let home = try #require(CloudMoveFolder(chat: "/Users/me"))
        #expect(!tabs.uploads(home, home: "/Users/me"))
        #expect(!tabs.uploads(try #require(CloudMoveFolder(chat: "/")), home: "/Users/me"))
        #expect(tabs.uploads(atRoot, home: "/Users/me"))
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
        let request = CloudStartChat.createRequest(key: "cloud-start-chat-k", sizedFor: nil, team: "team-a")
        #expect(request.idempotencyKey == "cloud-start-chat-k")
        #expect(request.team == "team-a")
        #expect(!request.wasSent)
        // The classic create sends to that team, not the app's team now; a sent try keeps its own.
        #expect(await CloudService.createTeam(sent: nil, requested: request.team) { "team-b" } == "team-a")
        #expect(await CloudService.createTeam(sent: nil, requested: nil) { "team-b" } == "team-b")
        #expect(await CloudService.createTeam(sent: .some("team-c"), requested: request.team) { "team-b" } == "team-c")
    }

    /// Not behind Labs (Leo, 2026-10-30: "that seems dumb. i dont like putting so much stuff in
    /// labs"): only Cloud off by policy and a signed-out account refuse.
    @Test func aCloudStartIsRefusedOnlyWhenCloudIsOffOrNobodyIsSignedIn() {
        #expect(CloudStartChat.refusal(cloudDisabled: false, signedIn: true) == nil)
        #expect(CloudStartChat.refusal(cloudDisabled: false, signedIn: false) == "not_signed_in")
        #expect(CloudStartChat.refusal(cloudDisabled: true, signedIn: true) == "cloud_disabled")
        #expect(CloudStartChat.refusal(cloudDisabled: true, signedIn: false) == "cloud_disabled")
        // The Cloud app server's link takes no folder copy: refused before a machine is created.
        #expect(CloudStartChat.refusal(cloudDisabled: false, signedIn: true, appServerLink: true) == "unavailable")
        #expect(CloudStartChat.refusal(cloudDisabled: false, signedIn: false, appServerLink: true) == "not_signed_in")
    }
}
