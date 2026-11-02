import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A new chat's first send with Cloud picked (`cloud.startChat`): like a Sandboxed send, only a
/// new chat with a fresh gesture reaches the App's runner, with its prompt, folder and agent, and
/// while it runs no chat starts here.
@Suite
@MainActor
struct AgentPaneCloudStartTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @MainActor private final class Starts { var seen: [AgentPaneCloudStart] = []; var heldDuringRun: Bool? }

    private static func pane(_ starts: Starts, sessionId: String? = nil, root: String? = nil) -> AgentPaneModel {
        let model = AgentPaneModel(host: NoHost(), sessionId: sessionId)
        if let root { model.transport.roots = { [root] } }
        model.onCloudStartChat = { [weak model] start in
            starts.seen.append(start)
            // A second hand-off in the same pane is refused while this one runs.
            starts.heldDuringRun = model?.transport.replacements.beginSandbox() == false
            return AgentPaneReply.success(["machine": "cloud-1"])
        }
        return model
    }

    private static func start(_ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "cloud.startChat", "params": params])
    }

    /// A real folder (the check reads the disk) under its own new root: (root, folder).
    private static func project() throws -> (root: String, folder: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-start-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("paint")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (root.path, folder.path)
    }

    private static func canonical(_ path: String) -> String? { AcpmuxPathPolicy.canonical(path) }

    private static let good: [String: Any] = ["task": "fix the build", "cwd": "/Users/me/src/paint", "harness": "codex", "model": "gpt-6-astra",
                                              "key": UUID().uuidString]

    @Test func aNewChatsSendWithAGestureStartsInCloud() async throws {
        let starts = Starts()
        let (root, folder) = try Self.project()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let model = Self.pane(starts, root: root)
        model.transport.gestures.record()
        let reply = await model.respond(to: Self.start(Self.good.merging(["cwd": folder]) { $1 }))
        #expect(reply["ok"] as? Bool == true)
        #expect(starts.seen.map(\.task) == ["fix the build"])
        // The runner gets the folder's canonical path, the one the pane's check allowed.
        #expect(starts.seen.first?.cwd == Self.canonical(folder))
        #expect(starts.seen.first?.harness == "codex")
        #expect(starts.seen.first?.model == "gpt-6-astra")
        #expect(starts.heldDuringRun == true)
        // A chat that started on the machine keeps the hold: this pane starts nothing more.
        #expect(!model.transport.replacements.beginSandbox())
    }

    @Test func theMachinesChatStartsWithThePromptAgentAndModelThePagePicked() throws {
        let start = try #require(AgentPaneCloudStart(params: Self.good))
        let seed = start.seed(cwd: "/home/cmux/work/paint-1a2b3c")
        #expect(seed.cwd == "/home/cmux/work/paint-1a2b3c")
        #expect(seed.prompt == "fix the build")
        #expect(seed.promptBy == .person)
        #expect(seed.harness == "codex")
        #expect(seed.model == "gpt-6-astra")
        // No model from the page: the harness's default on the machine.
        let unnamed = try #require(AgentPaneCloudStart(params: ["task": "t", "key": UUID().uuidString]))
        #expect(unnamed.seed(cwd: "/w").model == nil)
        #expect(unnamed.seed(cwd: "/w").harness == nil)
    }

    @Test func aChatWithNoProjectStartsInTheMachinesOwnFolder() throws {
        let home = try #require(AgentPaneCloudStart(params: ["task": "t", "key": UUID().uuidString, "home": true]))
        #expect(home.home && home.cwd == nil)
        #expect(home.seed(cwd: nil).cwd == nil)
        // Home names no folder: with a folder, or not a flag, it is refused.
        #expect(AgentPaneCloudStart(params: ["task": "t", "key": UUID().uuidString, "home": true, "cwd": "/w"]) == nil)
        #expect(AgentPaneCloudStart(params: ["task": "t", "key": UUID().uuidString, "home": "yes"]) == nil)
        #expect(try #require(AgentPaneCloudStart(params: Self.good)).home == false)
    }

    @Test func aRefusedStartReleasesTheHoldSoTheSendMayBeTriedAgain() async throws {
        let (root, folder) = try Self.project()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let model = AgentPaneModel(host: NoHost())
        model.transport.roots = { [root] }
        let starts = Starts()
        model.onCloudStartChat = { start in
            starts.seen.append(start)
            return AgentPaneReply.failure(code: "cloud_start_failed", message: "no machine")
        }
        model.transport.gestures.record()
        let reply = await model.respond(to: Self.start(Self.good.merging(["cwd": folder]) { $1 }))
        #expect(starts.seen.count == 1)
        #expect(reply["ok"] as? Bool == false)
        #expect(model.transport.replacements.beginSandbox())
    }

    @Test func noGestureAStartedOrRemoteChatOrABadRequestStartsNothing() async {
        let starts = Starts()
        _ = await Self.pane(starts).respond(to: Self.start(Self.good))
        let started = Self.pane(starts, sessionId: "chat")
        started.transport.gestures.record()
        _ = await started.respond(to: Self.start(Self.good))
        let starting = Self.pane(starts)
        starting.transport.gestures.record()
        starting.transport.replacements.set(waiting: 1)
        _ = await starting.respond(to: Self.start(Self.good))
        // A chat on another machine names its own paths, never a folder on this Mac to copy.
        let remote = Self.pane(starts)
        remote.remoteChat = true
        remote.transport.gestures.record()
        #expect(await remote.respond(to: Self.start(Self.good))["ok"] as? Bool != true)
        for bad: [String: Any] in [
            Self.good.merging(["task": "  "]) { $1 }, Self.good.merging(["cwd": "relative/path"]) { $1 },
            Self.good.merging(["key": "not-a-uuid"]) { $1 }, Self.good.merging(["harness": 3]) { $1 },
            Self.good.merging(["harness": String(repeating: "x", count: 200)]) { $1 },
        ] {
            let model = Self.pane(starts)
            model.transport.gestures.record()
            let reply = await model.respond(to: Self.start(bad))
            #expect(reply["ok"] as? Bool != true)
        }
        #expect(starts.seen.isEmpty)
    }

    @Test func aFolderOutsideThePanesRootsIsNeverCopied() async throws {
        let starts = Starts()
        let (root, folder) = try Self.project()
        let (outsideRoot, outside) = try Self.project()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outsideRoot)
        }
        // A link inside the root to a folder outside it names the outside folder.
        let link = (root as NSString).appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)
        for cwd in [outside, link, root + "/paint/../../" + (outsideRoot as NSString).lastPathComponent + "/paint",
                    root + "/missing", "/", NSHomeDirectory()] {
            let model = Self.pane(starts, root: root)
            model.transport.gestures.record()
            let reply = await model.respond(to: Self.start(Self.good.merging(["cwd": cwd]) { $1 }))
            #expect(reply["ok"] as? Bool != true, "\(cwd)")
            // Refused before the hold and the gesture: the person can pick another folder and send.
            #expect(model.transport.replacements.beginSandbox())
        }
        // A pane whose folder is home (a folderless tab) offers no folder under home by that alone.
        let homeTab = Self.pane(starts, root: NSHomeDirectory())
        homeTab.transport.gestures.record()
        let underHome = await homeTab.respond(to: Self.start(Self.good.merging(["cwd": NSHomeDirectory() + "/Library"]) { $1 }))
        #expect(underHome["ok"] as? Bool != true)
        #expect(starts.seen.isEmpty)
        // The root's own folder still starts.
        let model = Self.pane(starts, root: root)
        model.transport.gestures.record()
        #expect(await model.respond(to: Self.start(Self.good.merging(["cwd": folder]) { $1 }))["ok"] as? Bool == true)
    }

    /// The copy uploads the Git working copy that holds the folder: a grant of /repo/paint never
    /// uploads /repo (its siblings and its history); a grant of /repo does, as its upload root.
    @Test func aFolderInsideAGitWorkingCopyIsCopiedOnlyWhenTheWholeCopyIsInScope() async throws {
        let starts = Starts()
        let (repo, folder) = try Self.project()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try FileManager.default.createDirectory(atPath: (repo as NSString).appendingPathComponent(".git"), withIntermediateDirectories: true)
        let narrow = Self.pane(starts, root: folder)
        narrow.transport.gestures.record()
        let refused = await narrow.respond(to: Self.start(Self.good.merging(["cwd": folder]) { $1 }))
        #expect(refused["ok"] as? Bool != true)
        #expect(narrow.transport.replacements.beginSandbox())
        #expect(starts.seen.isEmpty)

        let whole = Self.pane(starts, root: repo)
        whole.transport.gestures.record()
        let started = await whole.respond(to: Self.start(Self.good.merging(["cwd": folder]) { $1 }))
        #expect(started["ok"] as? Bool == true)
        #expect(starts.seen.first?.cwd == Self.canonical(folder))
        #expect(starts.seen.first?.uploadRoot == Self.canonical(repo))
        let canonicalFolder = try #require(Self.canonical(folder))
        #expect(AgentPaneCloudStart.uploadRoot(of: canonicalFolder) == Self.canonical(repo))
    }

    /// Router review at 7149eba: a `.git` file (a linked worktree, `--separate-git-dir`) can name a
    /// repository outside the pane's roots, whose history the copy would upload. Such a send is
    /// refused; one whose git folders are in scope starts.
    @Test func aWorkingCopyWhoseGitFolderIsOutsideTheRootsIsNeverCopied() async throws {
        let starts = Starts()
        let (project, _) = try Self.project()
        let (outside, _) = try Self.project()
        defer { for path in [project, outside] { try? FileManager.default.removeItem(atPath: path) } }
        let external = (outside as NSString).appendingPathComponent("repo.git")
        let worktree = (external as NSString).appendingPathComponent("worktrees/project")
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        try "../..\n".write(toFile: (worktree as NSString).appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        try "gitdir: \(worktree)\n".write(toFile: (project as NSString).appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        #expect(AgentPaneCloudStart.gitFolders(of: project) == [worktree, external])

        let narrow = Self.pane(starts, root: project)
        narrow.transport.gestures.record()
        let refused = await narrow.respond(to: Self.start(Self.good.merging(["cwd": project]) { $1 }))
        #expect(refused["ok"] as? Bool != true)
        #expect(starts.seen.isEmpty)

        let both = Self.pane(starts)
        both.transport.roots = { [project, outside] }
        both.transport.gestures.record()
        #expect(await both.respond(to: Self.start(Self.good.merging(["cwd": project]) { $1 }))["ok"] as? Bool == true)
    }

    /// A folder of the New Tab page's scan is not the pane's to copy by the Send's gesture alone:
    /// only once the person picked it (a root of the pane, or one they added).
    @Test func aScannedProjectTheSendDidNotPickIsNeverCopied() async throws {
        let starts = Starts()
        let (root, folder) = try Self.project()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let model = Self.pane(starts)
        model.transport.gestureRoots = { [root] }
        model.transport.gestures.record()
        let refused = await model.respond(to: Self.start(Self.good.merging(["cwd": folder]) { $1 }))
        #expect(refused["ok"] as? Bool != true)
        #expect(starts.seen.isEmpty)
        // Picked (now one of the pane's roots): it starts.
        model.transport.roots = { [root] }
        model.transport.gestures.record()
        #expect(await model.respond(to: Self.start(Self.good.merging(["cwd": folder]) { $1 }))["ok"] as? Bool == true)
    }

    // The send's create, tab and copy keys are cmux-tui's (`link/start_chat_cli/tests.rs`).

    @Test func withoutARunnerTheMethodIsUnsupported() async {
        let model = AgentPaneModel(host: NoHost())
        model.transport.gestures.record()
        let reply = await model.respond(to: Self.start(Self.good))
        #expect(reply["ok"] as? Bool != true)
        #expect(AgentPaneCloudStart(params: ["task": "t", "cwd": "/a", "key": UUID().uuidString])?.harness == nil)
        // No folder from the page: the tab's own folder, on the App side.
        #expect(AgentPaneCloudStart(params: ["task": "t", "key": UUID().uuidString])?.cwd == nil)
    }

    /// Leo, 2026-10-31: he "picked zesty-indigo-lemur in the machine picker, but the chat stayed on
    /// sr2-tunnel-probe". `cloud.repickChat` names the picked machine; only a chat on another machine,
    /// with the pick's gesture, reaches the App.
    @Test func aRepickNamesTheMachineAndReachesTheAppOnlyForAChatElsewhereWithAGesture() async {
        #expect(AgentPaneRequest(body: ["method": "cloud.repickChat", "params": ["machine": "m_zesty"]])
            == .cloudRepickChat(AgentPaneCloudRepick(machine: "m_zesty", name: nil)))
        #expect(AgentPaneRequest(body: ["method": "cloud.repickChat", "params": ["name": "zesty-indigo-lemur"]])
            == .cloudRepickChat(AgentPaneCloudRepick(machine: nil, name: "zesty-indigo-lemur")))
        for bad: [String: Any] in [[:], ["machine": ""], ["name": 3], ["machine": "a", "other": "b"], ["name": "a\nb"]] {
            #expect(AgentPaneCloudRepick(params: bad) == nil, "\(bad)")
        }
        var seen: [AgentPaneCloudRepick] = []
        let model = AgentPaneModel(host: NoHost(), sessionId: "s1")
        model.onCloudRepickChat = { repick in
            seen.append(repick)
            return AgentPaneReply.success(["machine": "zesty-indigo-lemur"])
        }
        let request = AgentPaneRequest.cloudRepickChat(AgentPaneCloudRepick(machine: "m_zesty", name: nil))
        // A chat on this Mac: refused.
        model.transport.gestures.record()
        #expect(await model.respond(to: request)["ok"] as? Bool != true)
        model.remoteChat = true
        // No gesture: refused.
        model.transport.gestures.clearTickets()
        _ = model.transport.gestures.consume()
        #expect(await model.respond(to: request)["ok"] as? Bool != true)
        #expect(seen.isEmpty)
        model.transport.gestures.record()
        #expect(await model.respond(to: request)["ok"] as? Bool == true)
        #expect(seen == [AgentPaneCloudRepick(machine: "m_zesty", name: nil)])
    }

    /// A repick finds the picked machine by its id, else by the name acpmux lists it under (title or
    /// slug, any case), and never guesses between two of the same name.
    @Test func aRepickFindsThePickedMachineByIdOrByName() {
        let machines: [(id: String, title: String, slug: String?)] = [
            (id: "m_sr2", title: "sr2-tunnel-probe", slug: nil),
            (id: "m_zesty", title: "Zesty Indigo Lemur", slug: "zesty-indigo-lemur"),
            (id: "m_a", title: "twin", slug: nil), (id: "m_b", title: "twin", slug: nil),
        ]
        #expect(AgentPaneCloudRepick(machine: "m_zesty", name: nil).machineID(in: machines) == "m_zesty")
        #expect(AgentPaneCloudRepick(machine: "m_gone", name: nil).machineID(in: machines) == nil)
        #expect(AgentPaneCloudRepick(machine: nil, name: "zesty-indigo-lemur").machineID(in: machines) == "m_zesty")
        #expect(AgentPaneCloudRepick(machine: nil, name: "SR2-tunnel-probe").machineID(in: machines) == "m_sr2")
        #expect(AgentPaneCloudRepick(machine: nil, name: "twin").machineID(in: machines) == nil)
        #expect(AgentPaneCloudRepick(machine: nil, name: "nobody").machineID(in: machines) == nil)
    }
}
