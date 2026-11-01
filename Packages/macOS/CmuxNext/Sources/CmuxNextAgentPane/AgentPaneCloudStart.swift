import CmuxNextCompat
import CmuxNextSettings
public import Foundation

/// `cloud.startChat {task, cwd?, harness?, model?, key}`: a new chat's first send with Cloud picked
/// as where it runs (the environment picker's Cloud row, Labs). The App picks or makes a Cloud
/// machine sized for the chat, copies the chat's folder there, starts the chat there with this
/// prompt and shows it, with no machine, size or environment prompt (``AgentPaneModel/onCloudStartChat``).
public nonisolated struct AgentPaneCloudStart: Sendable, Equatable {
    /// The person's first prompt (never logged).
    public var task: String
    /// The chat's folder on this Mac, absolute; nil: the tab's own folder, or none with ``home``.
    public var cwd: String?
    /// The page said the chat has no project (cloudRun.ts `cloudStartFolder`): nothing is copied,
    /// and the chat starts in the machine's own folder for chats. Never with ``cwd``.
    public var home = false
    public var harness: String?
    public var model: String?
    /// The selected Cloud environment id; nil lets workspace ensure resolve personal Default.
    public var environment: String?
    /// The page's send: a second call with the same key while one runs is the same send.
    public var key: String
    /// The folder the copy uploads (the Git working copy that holds ``cwd``, else ``cwd``), set by
    /// the pane once it checked that folder against its roots too (``AgentPaneHandOff``); nil when
    /// the page named no folder. The App copies only this folder, never one it finds anew.
    public var uploadRoot: String?

    public init(task: String, cwd: String?, harness: String? = nil, model: String? = nil, key: String, environment: String? = nil) {
        (self.task, self.cwd, self.harness, self.model, self.key) = (task, cwd, harness, model, key)
        self.environment = environment
    }

    /// The page's params, checked; nil for anything else.
    public init?(params: [String: Any]?) {
        let name = { (key: String) -> String?? in
            guard let value = params?[key] else { return .some(nil) }
            guard let text = value as? String, !text.isEmpty, text.count <= 128 else { return nil }
            return .some(text)
        }
        guard let task = params?["task"] as? String, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              task.count <= AgentPaneRequest.maximumSandboxTask,
              let key = params?["key"] as? String, UUID(uuidString: key) != nil,
              let harness = name("harness"), let model = name("model"), let environment = name("environment") else { return nil }
        let cwd = params?["cwd"]
        if let cwd, !((cwd as? String).map { $0.hasPrefix("/") && !$0.contains("\0") && $0.count <= 4096 } ?? false) { return nil }
        let home = params?["home"]
        if let home, !(home is Bool) || cwd != nil { return nil }
        self.init(task: task, cwd: cwd as? String, harness: harness, model: model, key: key, environment: environment)
        self.home = home as? Bool ?? false
    }

    // The send's machine, its create, tab and copy keys and its pin are cmux-tui's
    // (`cmux link start-chat`, cmux-tui `link/start_chat_cli.rs`), keyed by ``key``.

    /// The folder `cmux link sync push` copies for a chat in `folder`: the nearest folder at or
    /// above it holding `.git` (a Git working copy's top), else `folder` itself (as
    /// `CloudMoveFolder` picks it). Reads the disk.
    public nonisolated static func uploadRoot(of folder: String) -> String {
        // The folder and each one above it, up to `/`: a bounded walk, one step per path component.
        let components = (folder as NSString).pathComponents
        for count in stride(from: components.count, through: 1, by: -1) {
            let current = NSString.path(withComponents: Array(components.prefix(count)))
            if FileManager.checked.fileExists(atPath: (current as NSString).appendingPathComponent(".git")) { return current }
        }
        return folder
    }

    /// The git folders `cmux link sync push` copies with the working copy at `root` (its objects and
    /// refs): `root/.git` when it is a folder, else the folder a `.git` file names (`gitdir: X`, a
    /// linked worktree or `--separate-git-dir`), plus the common folder that one's `commondir` names.
    /// Each may lie outside `root`, so the send checks them against the pane's roots too. Empty
    /// outside git. Reads the disk.
    public nonisolated static func gitFolders(of root: String) -> [String] {
        let dotGit = (root as NSString).appendingPathComponent(".git")
        var isFolder: ObjCBool = false
        guard FileManager.checked.fileExists(atPath: dotGit, isDirectory: &isFolder) else { return [] }
        func resolved(_ path: String, against base: String) -> String {
            let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
            return ((path.hasPrefix("/") ? path : (base as NSString).appendingPathComponent(path)) as NSString).standardizingPath
        }
        let own: String
        if isFolder.boolValue {
            own = dotGit
        } else {
            guard let text = try? String(blockingContentsOf: URL(fileURLWithPath: dotGit), encoding: .utf8),
                  let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:") else { return [dotGit] }
            own = resolved(String(line.dropFirst("gitdir:".count)), against: root)
        }
        var folders = [own]
        let commonFile = URL(fileURLWithPath: (own as NSString).appendingPathComponent("commondir"))
        if let common = try? String(blockingContentsOf: commonFile, encoding: .utf8), !common.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            folders.append(resolved(common, against: own))
        }
        return folders
    }

    /// Whether every one of `root`'s ``gitFolders(of:)`` is `root` or below it (by canonical path
    /// components): a folder copied with no pane check behind it (a tab's own folder) never uploads
    /// a repository a `.git` file or `commondir` names elsewhere. Reads the disk.
    public nonisolated static func gitFoldersAreInside(_ root: String) -> Bool {
        let base = ((AcpmuxPathPolicy.canonical(root) ?? root) as NSString).pathComponents
        return gitFolders(of: root).allSatisfy { folder in
            let parts = ((AcpmuxPathPolicy.canonical(folder) ?? (folder as NSString).standardizingPath) as NSString).pathComponents
            return parts.count >= base.count && Array(parts.prefix(base.count)) == base
        }
    }

    /// The seed of the chat on the Cloud machine, in `cwd` (the folder's copy there): the person's
    /// prompt, sent once with the Send's gesture, on the agent and model the page picked.
    public func seed(cwd: String?) -> AgentPaneSeed {
        AgentPaneSeed(cwd: cwd, prompt: task, promptBy: .person, harness: harness, model: model)
    }
}

/// A new chat's first send that runs somewhere other than this Mac's chat: a Sandboxed send
/// (`sandbox.run`) or a Cloud chat (`cloud.startChat`). Both are the Send's own gesture, only for a
/// chat that has not started or opened here, one at a time, and while one runs no chat starts or
/// opens here. The send line drains first, so a start or open the page handed over before is counted.
@MainActor
struct AgentPaneHandOff {
    let model: AgentPaneModel

    func sandbox(task: String, agent: String?, key: String) async -> [String: Any] {
        guard let run = model.onSandboxRun else { return AgentPaneModel.unsupported("sandbox.run") }
        return await held("sandbox.run") { replacements in
            await model.sandboxRuns.run(task: task, key: key) {
                defer { replacements.endSandbox() }
                return await run(task, agent, key)
            }
        }
    }

    func cloud(_ start: AgentPaneCloudStart) async -> [String: Any] {
        // The folder is a path on this Mac: a chat on another machine never names one to copy.
        guard let run = model.onCloudStartChat, !model.chatIsElsewhere else { return AgentPaneModel.unsupported("cloud.startChat") }
        // The page names the folder, and its whole tree is copied off this Mac: it must be one of
        // the pane's own folders (AcpmuxPathPolicy's roots, by canonical path and by components),
        // never home or above it, as for a chat that starts here. Nil: the App uses the tab's folder.
        var start = start
        start.uploadRoot = nil
        if let cwd = start.cwd {
            guard let folder = await Self.folderInScope(cwd, transport: model.transport) else {
                return AgentPaneModel.transportFailure(.pathOutsideRoots)
            }
            // What is copied is the Git working copy that holds the folder: it must be in scope too,
            // so a grant of /repo/project never uploads /repo, its siblings and its history.
            let root = await Task.detached(priority: .userInitiated) { AgentPaneCloudStart.uploadRoot(of: folder) }.value
            if root != folder {
                let checked = await Self.folderInScope(root, transport: model.transport)
                guard checked == root else { return AgentPaneModel.transportFailure(.pathOutsideRoots) }
            }
            // Its git folders are copied too (history, refs): a `.git` file or `commondir` that names a
            // repository outside the pane's roots never uploads it.
            let gitFolders = await Task.detached(priority: .userInitiated) { AgentPaneCloudStart.gitFolders(of: root) }.value
            for gitFolder in gitFolders {
                let checked = await Self.folderInScope(gitFolder, transport: model.transport)
                guard checked != nil else { return AgentPaneModel.transportFailure(.pathOutsideRoots) }
            }
            start.cwd = folder
            start.uploadRoot = root
        }
        return await held("cloud.startChat") { [start] replacements in
            let reply = await run(start)
            // A chat that started on the machine keeps the hold: this pane never starts one too,
            // also when the App could not close it.
            if reply["ok"] as? Bool != true { replacements.endSandbox() }
            return reply
        }
    }

    /// `cwd` canonical when it is a folder under one of the pane's roots and not the home folder
    /// or above it; nil otherwise. The roots are the pane's own (never home or above it) and the
    /// folders the person added or picked, as given. Never the New Tab page's scan and open folders
    /// (`gestureRoots`) by the Send's gesture alone: a folder there becomes a root only once the
    /// person picks it, and this send copies the folder off this Mac.
    static func folderInScope(_ cwd: String, transport: AgentPaneTransport) async -> String? {
        let roots = transport.roots(), granted = transport.addedRoots
        let home = transport.homeFolder
        return await Task.detached(priority: .userInitiated) { () -> String? in
            guard let folder = AcpmuxPathPolicy.canonical(cwd), AcpmuxPathPolicy.isDirectory(folder) else { return nil }
            let canonicalHome = home.flatMap(AcpmuxPathPolicy.canonical)
            guard !AgentHome.isHomeOrAbove(folder, home: canonicalHome) else { return nil }
            let own = roots.compactMap(AcpmuxPathPolicy.canonical).filter { !AgentHome.isHomeOrAbove($0, home: canonicalHome) }
            let allowed = own + granted.compactMap(AcpmuxPathPolicy.canonical).filter { $0 != "/" }
            return allowed.contains { AcpmuxPathPolicy.contains(root: $0, path: folder) } ? folder : nil
        }.value
    }

    /// The shared guards, then `body` with the replacements held (it ends the hold).
    private func held(_ method: String, _ body: @MainActor (AcpmuxPaneReplacements) async -> [String: Any]) async -> [String: Any] {
        guard model.sessionId == nil else { return AgentPaneModel.unsupported(method) }
        let notNow = AgentPaneReply.failure(code: "unavailable_now", message: "unavailable_now")
        let transport = model.transport
        guard await transport.lineDrained(within: .seconds(5)) else { return notNow }
        if let refusal = model.sandboxRuns.refusal { return AgentPaneReply.failure(code: refusal, message: refusal) }
        let replacements = transport.replacements
        guard replacements.beginSandbox() else { return notNow }
        guard transport.gestures.consume() else {
            replacements.endSandbox()
            return AgentPaneModel.transportFailure(.gestureRequired)
        }
        return await body(replacements)
    }
}

extension AgentPaneCloudStart {
    /// How this start goes, for the card under the message (webviews `cloudStartProgress.ts`): the
    /// step it is on (`machine`, `folder`, `opening`), the folder it copies, and the machine and its
    /// size once known, keyed by the page's send so a card for another start ignores it.
    @MainActor public func progress(_ step: String, folder: String? = nil, machine: String? = nil, size: String? = nil,
                                    cloneState: String? = nil, clonePhase: String? = nil,
                                    cloneStartedAt: Double? = nil, cloneFinishedAt: Double? = nil,
                                    to view: AgentPaneView) {
        var value: [String: JSONValue] = ["key": .string(key), "step": .string(step)]
        if let folder { value["folder"] = .string(folder) }
        if let machine { value["machine"] = .string(machine) }
        if let size { value["size"] = .string(size) }
        var cloneFields: [String: JSONValue] = [:]
        if let cloneState { cloneFields["state"] = .string(cloneState) }
        if let clonePhase { cloneFields["phase"] = .string(clonePhase) }
        if let cloneStartedAt { cloneFields["startedAt"] = .number(cloneStartedAt) }
        if let cloneFinishedAt { cloneFields["finishedAt"] = .number(cloneFinishedAt) }
        if !cloneFields.isEmpty { value["clone"] = .object(cloneFields) }
        let push = JSONValue.object(value)
        view.deliver([AgentPageEvent(kind: "cloudStartProgress", value: push)],
                     scripts: ["window.cmuxAcpmuxBridge?.cloudStartProgress?.(\(push.compactText));"])
    }
}
