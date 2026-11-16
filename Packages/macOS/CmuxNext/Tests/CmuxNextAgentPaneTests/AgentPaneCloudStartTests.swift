import CmuxNextSettings
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

    private static func code(_ reply: [String: Any]) -> String? { (reply["error"] as? [String: Any])?["code"] as? String }

    private static let cancel = AgentPaneRequest(body: ["method": "cloud.signInCancel"])

    /// The card's Sign in for start `key` (`cloud.signIn {key}`); the page owns the wait (cloudSignIn.ts).
    private static func signIn(_ key: String) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "cloud.signIn", "params": ["key": key]])
    }

    /// The page's send again of start `key` once its `cloud.signIn` signed in.
    private static func signedIn(_ key: String) -> AgentPaneRequest {
        start(["task": "preserved prompt", "key": key, "home": true, "signedIn": true])
    }

    @Test func aSignInOnAClickKeepsThatClickForItsStartOnce() async {
        let starts = Starts()
        let model = Self.pane(starts)
        var signIns = 0
        model.onCloudSignIn = {
            signIns += 1
            // The click is spent on the sign-in; nothing starts while the browser is open.
            #expect(!model.transport.gestures.isAvailable)
            #expect(starts.seen.isEmpty)
            return true
        }
        let key = UUID().uuidString
        // A scripted request opens no browser.
        #expect(Self.code(await model.respond(to: Self.signIn(key))) == "transport.gesture_required")
        #expect(signIns == 0)
        model.transport.gestures.record()
        let reply = await model.respond(to: Self.signIn(key))
        #expect(reply["ok"] as? Bool == true)
        #expect((reply["value"] as? [String: Any])?["signedIn"] as? Bool == true)
        #expect(signIns == 1)
        #expect(starts.seen.isEmpty)
        // The send again needs no gesture: the sign-in kept its click for this start, once.
        #expect(await model.respond(to: Self.signedIn(key))["ok"] as? Bool == true)
        #expect(starts.seen.map(\.task) == ["preserved prompt"])
        model.transport.replacements.endSandbox()
        #expect(Self.code(await model.respond(to: Self.signedIn(key))) == "cloud_sign_in_cancelled")
        #expect(starts.seen.count == 1)
    }

    /// The race the kept click closes: the browser returns, then the page leaves Cloud before it
    /// sends again. Its cancel drops the click, so a send that still arrives starts nothing.
    @Test func leavingCloudAfterAuthCompletesSendsNothing() async {
        let starts = Starts()
        let model = Self.pane(starts)
        model.onCloudSignIn = { true }
        model.transport.gestures.record()
        let key = UUID().uuidString
        #expect(await model.respond(to: Self.signIn(key))["ok"] as? Bool == true)
        #expect(await model.respond(to: Self.cancel)["ok"] as? Bool == true)
        // A fresh click does not stand in for the dropped one.
        model.transport.gestures.record()
        #expect(Self.code(await model.respond(to: Self.signedIn(key))) == "cloud_sign_in_cancelled")
        #expect(starts.seen.isEmpty)
    }

    /// The kept click authorizes only the start it was kept for: another key, or a send again
    /// with no sign-in before it, starts nothing, and does not spend the person's click.
    @Test func aSignedInSendStartsOnlyTheStartItsSignInKept() async {
        let starts = Starts()
        let model = Self.pane(starts)
        model.onCloudSignIn = { true }
        let other = Self.signedIn(UUID().uuidString)
        model.transport.gestures.record()
        #expect(Self.code(await model.respond(to: other)) == "cloud_sign_in_cancelled")
        #expect(model.transport.gestures.isAvailable)
        let key = UUID().uuidString
        #expect(await model.respond(to: Self.signIn(key))["ok"] as? Bool == true)
        #expect(Self.code(await model.respond(to: other)) == "cloud_sign_in_cancelled")
        // That try spent the kept click: the right key comes too late.
        #expect(Self.code(await model.respond(to: Self.signedIn(key))) == "cloud_sign_in_cancelled")
        #expect(starts.seen.isEmpty)
    }

    @Test func aSignInThatEndsSignedOutKeepsNoClick() async {
        let starts = Starts()
        let model = Self.pane(starts)
        model.onCloudSignIn = { false }
        model.transport.gestures.record()
        let key = UUID().uuidString
        #expect(Self.code(await model.respond(to: Self.signIn(key))) == "not_signed_in")
        #expect(Self.code(await model.respond(to: Self.signedIn(key))) == "cloud_sign_in_cancelled")
        #expect(starts.seen.isEmpty)
    }

    /// The page left Cloud while the browser was open: the sign-in stands, but it keeps no click.
    @Test func leavingCloudDuringSignInKeepsNoClick() async {
        let starts = Starts()
        let model = Self.pane(starts)
        model.onCloudSignIn = {
            #expect(await model.respond(to: Self.cancel)["ok"] as? Bool == true)
            return true
        }
        model.transport.gestures.record()
        let key = UUID().uuidString
        #expect(Self.code(await model.respond(to: Self.signIn(key))) == "cloud_sign_in_cancelled")
        #expect(Self.code(await model.respond(to: Self.signedIn(key))) == "cloud_sign_in_cancelled")
        #expect(starts.seen.isEmpty)
    }

    /// Signed in meanwhile (Settings, another pane or window): the click resumes without the browser.
    @Test func anAccountAlreadySignedInSignsInWithoutTheBrowser() async {
        let starts = Starts()
        let model = Self.pane(starts)
        var signIns = 0
        model.onCloudSignIn = {
            signIns += 1
            return true
        }
        model.onCloudSignedIn = { true }
        model.transport.gestures.record()
        let key = UUID().uuidString
        #expect(await model.respond(to: Self.signIn(key))["ok"] as? Bool == true)
        #expect(signIns == 0)
        #expect(await model.respond(to: Self.signedIn(key))["ok"] as? Bool == true)
        #expect(starts.seen.count == 1)
    }

    /// The page's deadline passed (`cloud.signInCancel {expired: true}`): the browser sign-in it waited
    /// on is cancelled, so its Sign in again opens a fresh one instead of waiting on the abandoned one.
    @Test func anExpiredSignInEndsItsBrowserSignIn() async {
        let starts = Starts()
        let model = Self.pane(starts)
        model.onCloudSignIn = {
            try? await Task.sleep(for: .seconds(600))
            return !Task.isCancelled
        }
        model.transport.gestures.record()
        let key = UUID().uuidString
        let reply = Task { Self.code(await model.respond(to: Self.signIn(key))) }
        let deadline = ContinuousClock.now + .seconds(10)
        while model.cloudSignInBrowser == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(model.cloudSignInBrowser != nil)
        let expired = AgentPaneRequest(body: ["method": "cloud.signInCancel", "params": ["expired": true]])
        #expect(await model.respond(to: expired)["ok"] as? Bool == true)
        #expect(model.cloudSignInBrowser == nil)
        #expect(await reply.value == "not_signed_in")
        #expect(starts.seen.isEmpty)
    }

    /// Left Cloud and came back while the browser is still open: the new click waits on that same
    /// browser sign-in, and opens no second one.
    @Test func aClickAfterACancelWaitsOnTheSameBrowserSignIn() async {
        let starts = Starts()
        let model = Self.pane(starts)
        var signIns = 0
        let opened = AsyncStream<Void>.makeStream()
        let browser = AsyncStream<Bool>.makeStream()
        model.onCloudSignIn = {
            signIns += 1
            opened.continuation.yield()
            for await signedIn in browser.stream { return signedIn }
            return false
        }
        let first = UUID().uuidString, second = UUID().uuidString
        model.transport.gestures.record()
        let left = Task { Self.code(await model.respond(to: Self.signIn(first))) }
        for await _ in opened.stream { break }
        #expect(await model.respond(to: Self.cancel)["ok"] as? Bool == true)
        model.transport.gestures.record()
        let back = Task { Self.code(await model.respond(to: Self.signIn(second))) }
        for _ in 0..<50 { await Task.yield() }
        #expect(signIns == 1)
        browser.continuation.yield(true)
        browser.continuation.finish()
        #expect(await left.value == "cloud_sign_in_cancelled")
        #expect(await back.value == nil)
        #expect(signIns == 1)
        #expect(model.cloudSignInBrowser == nil)
        #expect(await model.respond(to: Self.signedIn(second))["ok"] as? Bool == true)
        #expect(starts.seen.count == 1)
    }

    /// A chat opened in this pane: its Cloud start card's sign-in is gone with it.
    @Test func aPaneWithAChatSignsNothingIn() async {
        let starts = Starts()
        let model = Self.pane(starts, sessionId: "chat-1")
        model.onCloudSignIn = { true }
        model.transport.gestures.record()
        #expect(Self.code(await model.respond(to: Self.signIn(UUID().uuidString))) == "unsupported")
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

    /// What the sending tab's composer held while the start ran (its unsent text) is the started chat's
    /// draft, shown and never sent, beside the prompt that goes by itself; an attachment-only start too.
    @Test func theStartedChatsDraftIsWhatTheSendingTabTypedMeanwhile() throws {
        let start = try #require(AgentPaneCloudStart(params: Self.good))
        let seed = start.seed(cwd: "/w", draft: "and the nightly")
        #expect(seed.draft == "and the nightly")
        #expect(seed.prompt == "fix the build")
        #expect(start.seed(cwd: "/w").draft == nil)
        let image = JSONValue.object(["id": .string("shot"), "kind": .string("image"), "name": .string("shot.png")])
        let chipsOnly = try #require(AgentPaneCloudStart(params: ["task": "", "key": UUID().uuidString, "attachments": [image.foundationObject]]))
        let attached = chipsOnly.seed(cwd: nil, draft: "and the nightly")
        #expect(attached.draft == "and the nightly")
        #expect(attached.promptAttachments == [image])
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

    /// The folder the composer shows as the chat's starts in Cloud on the Send's gesture, also when
    /// it is not one of the tab's roots (a recent project, a link to one): the gesture is the pick,
    /// as for a typed folder of a chat that starts here. Never home or above it, a missing folder,
    /// or any folder without the gesture.
    @Test func theComposersFolderStartsInCloudOnTheSendsGestureButNeverHomeOrAbove() async throws {
        let starts = Starts()
        let (root, _) = try Self.project()
        let (outsideRoot, outside) = try Self.project()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outsideRoot)
        }
        let link = (root as NSString).appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)
        for cwd in [outside, link, root + "/../" + (outsideRoot as NSString).lastPathComponent + "/paint"] {
            starts.seen = []
            let model = Self.pane(starts, root: root)
            model.transport.gestures.record()
            let reply = await model.respond(to: Self.start(Self.good.merging(["cwd": cwd]) { $1 }))
            #expect(reply["ok"] as? Bool == true, "\(cwd): \(reply)")
            #expect(starts.seen.first?.cwd == Self.canonical(outside), "\(cwd)")
        }
        starts.seen = []
        for cwd in [root + "/missing", "/", NSHomeDirectory(), (NSHomeDirectory() as NSString).deletingLastPathComponent] {
            let model = Self.pane(starts, root: root)
            model.transport.gestures.record()
            let reply = await model.respond(to: Self.start(Self.good.merging(["cwd": cwd]) { $1 }))
            #expect(reply["ok"] as? Bool != true, "\(cwd)")
            // Refused before the hold and the gesture: the person can pick another folder and send.
            #expect(model.transport.replacements.beginSandbox())
        }
        // Without the Send's gesture nothing is copied.
        let noGesture = Self.pane(starts, root: root)
        let refused = await noGesture.respond(to: Self.start(Self.good.merging(["cwd": outside]) { $1 }))
        #expect(refused["ok"] as? Bool != true)
        #expect(starts.seen.isEmpty)
    }

    /// Leo's nightly: a tab whose folder is inside a Git working copy (a repo's `briefs/<lane>`)
    /// refused its Cloud start with "This folder isn't open in this tab" ("what's this"), since the
    /// copy uploads the whole working copy and only the subfolder was a root. It starts, and the
    /// copy is the working copy that holds the folder.
    @Test func aFolderInsideAGitWorkingCopyStartsInCloudAndCopiesTheWorkingCopy() async throws {
        let starts = Starts()
        let (repo, folder) = try Self.project()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try FileManager.default.createDirectory(atPath: (repo as NSString).appendingPathComponent(".git"), withIntermediateDirectories: true)
        let narrow = Self.pane(starts, root: folder)
        narrow.transport.gestures.record()
        let started = await narrow.respond(to: Self.start(Self.good.merging(["cwd": folder]) { $1 }))
        #expect(started["ok"] as? Bool == true, "\(started)")
        #expect(starts.seen.first?.cwd == Self.canonical(folder))
        #expect(starts.seen.first?.uploadRoot == Self.canonical(repo))
        let canonicalFolder = try #require(Self.canonical(folder))
        #expect(AgentPaneCloudStart.uploadRoot(of: canonicalFolder) == Self.canonical(repo))
    }

    /// A `.git` file (a linked worktree, `--separate-git-dir`) names git folders elsewhere: they are
    /// copied with the working copy, but one that is home or above it never is.
    @Test func aWorkingCopyWhoseGitFolderIsHomeOrAboveIsNeverCopied() async throws {
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

        let linked = Self.pane(starts, root: project)
        linked.transport.gestures.record()
        #expect(await linked.respond(to: Self.start(Self.good.merging(["cwd": project]) { $1 }))["ok"] as? Bool == true)

        // A commondir that names `/` is never copied.
        try "/\n".write(toFile: (worktree as NSString).appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        starts.seen = []
        let rooted = Self.pane(starts, root: project)
        rooted.transport.gestures.record()
        let refused = await rooted.respond(to: Self.start(Self.good.merging(["cwd": project]) { $1 }))
        #expect(refused["ok"] as? Bool != true)
        #expect(starts.seen.isEmpty)
    }

    /// A folder of the New Tab page's scan (a recent project the chip shows that nobody clicked)
    /// starts in Cloud on the Send's gesture: the Send is the pick.
    @Test func aScannedProjectTheChipShowsStartsInCloudOnTheSendsGesture() async throws {
        let starts = Starts()
        let (root, folder) = try Self.project()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let model = Self.pane(starts)
        model.transport.gestureRoots = { [root] }
        model.transport.gestures.record()
        let reply = await model.respond(to: Self.start(Self.good.merging(["cwd": folder]) { $1 }))
        #expect(reply["ok"] as? Bool == true, "\(reply)")
        #expect(starts.seen.first?.cwd == Self.canonical(folder))
    }

    /// The reply's error code and message.
    private static func refusal(_ reply: [String: Any]) -> (code: String?, message: String?) {
        let error = reply["error"] as? [String: Any]
        return (error?["code"] as? String, error?["userMessage"] as? String)
    }

    /// cmux#35006: a Cloud start never copies a credential folder under home (~/.ssh, ~/.aws, …), one
    /// inside it, or a folder that holds one (~/.config holds gcloud's), by any spelling of its case;
    /// its refusal names the folder. A project folder under the same home still starts.
    @Test func aCredentialFolderOrOneHoldingItIsNeverCopiedAndTheRefusalNamesIt() async throws {
        let starts = Starts()
        let (home, project) = try Self.project()
        defer { try? FileManager.default.removeItem(atPath: home) }
        for folder in [".ssh/keys", ".aws", ".gnupg", ".config/gcloud", ".kube", ".docker", ".secrets", ".azure", "Library/Keychains"] {
            try FileManager.default.createDirectory(atPath: (home as NSString).appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let cases: [(String, String)] = [(".ssh", "~/.ssh"), (".ssh/keys", "~/.ssh"), (".aws", "~/.aws"), (".gnupg", "~/.gnupg"),
                                         (".config", "~/.config/gcloud"), (".config/gcloud", "~/.config/gcloud"), (".kube", "~/.kube"),
                                         (".docker", "~/.docker"), (".secrets", "~/.secrets"), (".azure", "~/.azure"),
                                         ("Library", "~/Library/Keychains"), ("Library/Keychains", "~/Library/Keychains"), (".SSH", "~/.ssh")]
        for (relative, named) in cases {
            let model = Self.pane(starts)
            model.transport.homeFolder = home
            model.transport.gestures.record()
            let reply = await model.respond(to: Self.start(Self.good.merging(["cwd": (home as NSString).appendingPathComponent(relative)]) { $1 }))
            #expect(reply["ok"] as? Bool != true, "\(relative)")
            #expect(Self.refusal(reply).code == "cloud_folder_secret", "\(relative): \(reply)")
            #expect(Self.refusal(reply).message == named, "\(relative): \(reply)")
            #expect(model.transport.replacements.beginSandbox())
        }
        #expect(starts.seen.isEmpty)
        // A project folder still starts, and so does one in iCloud Drive or a cloud-storage folder
        // under ~/Library (review of #35019 at 8f03b2c: all of ~/Library refused them).
        let iCloud = (home as NSString).appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/paint")
        let dropbox = (home as NSString).appendingPathComponent("Library/CloudStorage/Dropbox/paint")
        for folder in [iCloud, dropbox] { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        for cwd in [project, iCloud, dropbox] {
            let model = Self.pane(starts)
            model.transport.homeFolder = home
            model.transport.gestures.record()
            let started = await model.respond(to: Self.start(Self.good.merging(["cwd": cwd]) { $1 }))
            #expect(started["ok"] as? Bool == true, "\(cwd): \(started)")
        }
    }

    /// cmux#35005: a folder that is gone, and home or above it, each get their own code, never the
    /// "isn't open in this tab" refusal (`transport.path_outside_roots`).
    @Test func aMissingFolderAndHomeOrAboveEachSayWhy() async throws {
        let starts = Starts()
        let (home, project) = try Self.project()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let file = (project as NSString).appendingPathComponent("notes.txt")
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        let cases = [(project + "/missing", "cloud_folder_missing"), (file, "cloud_folder_missing"),
                     (home, "cloud_folder_home"), ((home as NSString).deletingLastPathComponent, "cloud_folder_home"), ("/", "cloud_folder_home")]
        for (cwd, code) in cases {
            let model = Self.pane(starts)
            model.transport.homeFolder = home
            model.transport.gestures.record()
            let reply = await model.respond(to: Self.start(Self.good.merging(["cwd": cwd]) { $1 }))
            #expect(Self.refusal(reply).code == code, "\(cwd): \(reply)")
            #expect(AgentPaneHandOff.refusedHere(reply) == code)
        }
        #expect(starts.seen.isEmpty)
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

    /// A start this pane refused before the App's start ran is logged under `app.cloud`, by code: the
    /// pane's transport refusals and its own guards, never a success or the App's own failure.
    @Test func aRefusalHereIsTheRefusedHereCode() {
        let outside = AgentPaneModel.transportFailure(.pathOutsideRoots)
        #expect(AgentPaneHandOff.refusedHere(outside) == AgentPaneTransportError.pathOutsideRoots.rawValue)
        for code in ["cloud_attachments", "unsupported", "unavailable_now", "sandbox_busy", "sandbox_spent"] {
            #expect(AgentPaneHandOff.refusedHere(AgentPaneReply.failure(code: code, message: code)) == code)
        }
        #expect(AgentPaneHandOff.refusedHere(AgentPaneReply.failure(code: "cloud_start_failed", message: "No machine")) == nil)
        #expect(AgentPaneHandOff.refusedHere(AgentPaneReply.success(["machine": "cloud-1"])) == nil)
        #expect(AgentPaneHandOff.refusedHere([:]) == nil)
    }
}

@Suite
@MainActor
struct AgentPaneCloudReservationTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func aNewLocalComposeForwardsWarmAndReleaseWithoutConsumingTheSendGesture() async throws {
        let model = AgentPaneModel(host: NoHost())
        var requests: [AgentPaneCloudReservationRequest] = []
        model.onCloudReservation = { request in
            requests.append(request)
            return ["ok": true, "machine": "vm-warm"]
        }
        let key = UUID().uuidString
        model.transport.gestures.record()
        for method in ["cloud.reserve", "cloud.releaseReservation"] {
            let request = AgentPaneRequest(body: ["method": method, "params": ["composeKey": key]])
            let answer = await model.respond(to: request)
            #expect(answer["ok"] as? Bool == true)
        }
        #expect(!model.transport.gestures.consume())
        #expect(requests.map(\.release) == [false, true])
        #expect(requests.first?.params["composeKey"]?.stringValue == key)
        model.remoteChat = true
        _ = await model.respond(to: AgentPaneRequest(body: ["method": "cloud.reserve", "params": ["composeKey": key]]))
        #expect(requests.count == 2)
    }

    /// A Send that stopped waiting for a slow reserve (cloudComposeReservation.ts) goes without it: the
    /// pane releases the reserve as it answers, so no machine stays reserved after the tab closes.
    @Test func aReserveThatAnswersAfterTheSendWentWithoutItIsReleasedHere() async throws {
        let model = AgentPaneModel(host: NoHost())
        var requests: [AgentPaneCloudReservationRequest] = []
        model.onCloudReservation = { [weak model] request in
            requests.append(request)
            // The Send arrives while the reserve is out, and goes without it.
            if !request.release { model?.dropCloudReservation() }
            return ["ok": true, "machine": "vm-late"]
        }
        let key = UUID().uuidString
        model.transport.gestures.record()
        let answer = await model.respond(to: AgentPaneRequest(body: ["method": "cloud.reserve", "params": ["composeKey": key]]))
        #expect(answer["ok"] as? Bool == false)
        #expect(requests.map(\.release) == [false, true])
        #expect(requests.last?.params["composeKey"]?.stringValue == key)
        #expect(!model.ownsCloudReservation(key))
        // The page's own release after it settles finds nothing left to release.
        _ = await model.respond(to: AgentPaneRequest(body: ["method": "cloud.releaseReservation", "params": ["composeKey": key]]))
        #expect(requests.count == 2)
    }

    @Test func reservationNeedsACloudPickGestureAndStaysSinglePerPane() async throws {
        let model = AgentPaneModel(host: NoHost())
        var requests: [AgentPaneCloudReservationRequest] = []
        model.onCloudReservation = { request in
            requests.append(request)
            return ["ok": true]
        }
        let first = UUID().uuidString
        let second = UUID().uuidString
        let noGesture = await model.respond(to: AgentPaneRequest(body: [
            "method": "cloud.reserve", "params": ["composeKey": first],
        ]))
        #expect((noGesture["error"] as? [String: Any])?["code"] as? String == "transport.gesture_required")

        model.transport.gestures.record()
        let reserved = await model.respond(to: AgentPaneRequest(body: [
            "method": "cloud.reserve", "params": ["composeKey": first],
        ]))
        #expect(reserved["ok"] as? Bool == true)
        let duplicate = await model.respond(to: AgentPaneRequest(body: [
            "method": "cloud.reserve", "params": ["composeKey": second],
        ]))
        #expect((duplicate["error"] as? [String: Any])?["code"] as? String == "unavailable_now")
        #expect(requests.map(\.composeKey) == [first])

        let released = await model.respond(to: AgentPaneRequest(body: [
            "method": "cloud.releaseReservation", "params": ["composeKey": first],
        ]))
        #expect(released["ok"] as? Bool == true)
    }

    @Test func sendForwardsOnlyAValidReservationKey() throws {
        let reservation = UUID().uuidString
        let ticket = UUID().uuidString
        let params: [String: Any] = ["task": "hello", "key": UUID().uuidString, "reservationKey": reservation, "gestureTicket": ticket]
        #expect(try #require(AgentPaneCloudStart(params: params)).reservationKey == reservation)
        #expect(try #require(AgentPaneCloudStart(params: params)).gestureTicket == ticket)
        #expect(AgentPaneCloudStart(params: params.merging(["reservationKey": "invalid"]) { $1 }) == nil)
        #expect(AgentPaneCloudStart(params: params.merging(["reservationKey": 123]) { $1 }) == nil)
        #expect(AgentPaneCloudStart(params: params.merging(["gestureTicket": "invalid"]) { $1 }) == nil)
        #expect(AgentPaneCloudStart(params: params.merging(["gestureTicket": 123]) { $1 }) == nil)
    }
}
