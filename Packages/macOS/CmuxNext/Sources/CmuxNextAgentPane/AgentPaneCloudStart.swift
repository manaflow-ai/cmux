public import CmuxNextCloud
import CmuxNextCompat
public import CmuxNextSettings
public import Foundation
import os

/// `cloud.startChat {task, cwd?, harness?, model?, key}`: a new chat's first send with Cloud picked
/// as where it runs (the environment picker's Cloud row, Labs). The App picks or makes a Cloud
/// machine sized for the chat, copies the chat's folder there, starts the chat there with this
/// prompt and shows it, with no machine, size or environment prompt (``AgentPaneModel/onCloudStartChat``).
public nonisolated struct AgentPaneCloudStart: Sendable, Equatable {
    /// The person's first prompt (never logged).
    public var task: String
    /// The composer's chips, in draft order. Mac paths are never used as file-read authority.
    public var attachments: [JSONValue] = []
    /// The chat's folder on this Mac, absolute; nil: the tab's own folder, or none with ``home``.
    public var cwd: String?
    /// The page said the chat has no project (cloudRun.ts `cloudStartFolder`): nothing is copied,
    /// and the chat starts in the machine's own folder for chats. Never with ``cwd``.
    public var home = false
    public var harness: String?
    public var model: String?
    /// The selected Cloud environment id; nil lets workspace ensure resolve personal Default.
    public var environment: String?
    /// The warm machine reserved by this compose; Send binds it using ``key``.
    public var reservationKey: String?
    /// Native Send authorization reserved before waiting for the speculative lease.
    var gestureTicket: String?
    /// The page's send: a second call with the same key while one runs is the same send.
    public var key: String
    /// The folder the copy uploads (the Git working copy that holds ``cwd``, else ``cwd``), set by
    /// the pane once it checked that folder against its roots too (``AgentPaneHandOff``); nil when
    /// the page named no folder. The App copies only this folder, never one it finds anew.
    public var uploadRoot: String?

    public init(task: String, cwd: String?, harness: String? = nil, model: String? = nil, key: String, environment: String? = nil, reservationKey: String? = nil, gestureTicket: String? = nil) {
        (self.task, self.cwd, self.harness, self.model, self.key) = (task, cwd, harness, model, key)
        self.environment = environment
        self.reservationKey = reservationKey
        self.gestureTicket = gestureTicket
    }

    /// The page's params, checked; nil for anything else.
    public init?(params: [String: Any]?) {
        let name = { (key: String) -> String?? in
            guard let value = params?[key] else { return .some(nil) }
            guard let text = value as? String, !text.isEmpty, text.count <= 128 else { return nil }
            return .some(text)
        }
        let attachments: [JSONValue]
        if let value = params?["attachments"] {
            guard let json = JSONValue(foundation: value), let list = json.arrayValue,
                  list.allSatisfy({ $0.objectValue != nil }) else { return nil }
            attachments = list
        } else { attachments = [] }
        guard let task = params?["task"] as? String,
              !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty,
              task.count <= AgentPaneRequest.maximumSandboxTask,
              let key = params?["key"] as? String, UUID(uuidString: key) != nil,
              let harness = name("harness"), let model = name("model"), let environment = name("environment") else { return nil }
        let reservationKey = params?["reservationKey"]
        if let reservationKey, (reservationKey as? String).flatMap(UUID.init(uuidString:)) == nil { return nil }
        let gestureTicket = params?["gestureTicket"]
        if let gestureTicket, (gestureTicket as? String).flatMap(UUID.init(uuidString:)) == nil { return nil }
        let cwd = params?["cwd"]
        if let cwd, !((cwd as? String).map { $0.hasPrefix("/") && !$0.contains("\0") && $0.count <= 4096 } ?? false) { return nil }
        let home = params?["home"]
        if let home, !(home is Bool) || cwd != nil { return nil }
        self.init(task: task, cwd: cwd as? String, harness: harness, model: model, key: key, environment: environment, reservationKey: reservationKey as? String, gestureTicket: gestureTicket as? String)
        self.home = home as? Bool ?? false
        self.attachments = attachments
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
    /// Each may lie outside `root`, so the send checks each the way it checks the folder. Empty
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
        AgentPaneSeed(cwd: cwd, prompt: task, promptAttachments: attachments.isEmpty ? nil : attachments,
                      promptBy: .person, harness: harness, model: model)
    }
}

/// `cloud.repickChat {machine?, name?}`: the person picked another machine in the environment picker
/// for a Cloud chat whose first send has not run (it failed, say "Claude is not signed in here"). The
/// App moves the chat there and sends its first prompt again (``AgentPaneModel/onCloudRepickChat``,
/// CmuxNextApp `CloudStartChat+Repick`), rather than leaving it on the machine it was on. `machine`: an
/// account Cloud machine's id (a row acpmux does not list); `name`: the machine's name as acpmux lists
/// it as a peer. At least one. Leo, 2026-10-31: he "picked zesty-indigo-lemur in the machine picker,
/// but the chat stayed on sr2-tunnel-probe".
public nonisolated struct AgentPaneCloudRepick: Sendable, Equatable {
    public var machine: String?
    public var name: String?

    public init(machine: String?, name: String?) {
        (self.machine, self.name) = (machine, name)
    }

    /// The page's params, checked; nil for anything else.
    public init?(params: [String: Any]?) {
        let params = params ?? [:]
        guard Set(params.keys).isSubset(of: ["machine", "name"]) else { return nil }
        func text(_ key: String) -> String?? {
            guard let value = params[key] else { return .some(nil) }
            guard let text = value as? String, !text.isEmpty, text.utf8.count <= 128,
                  text.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return .some(text)
        }
        guard let machine = text("machine"), let name = text("name"), machine != nil || name != nil else { return nil }
        self.init(machine: machine, name: name)
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
        // Read as the send is issued, before `held` waits on the send line: the tab may close by then (#31109).
        let incognito = model.sendIsIncognito?() ?? true
        return await held("sandbox.run") { replacements in
            await model.sandboxRuns.run(task: task, key: key) {
                defer { replacements.endSandbox() }
                return await run(task, agent, key, incognito)
            }
        }
    }

    private static let cloudLog = Logger(subsystem: "com.cmuxterm.app.next", category: "app.cloud")

    /// `cloud.startChat`, and a refusal made here, before the App's start ran (the folder check, the
    /// gesture, an attachment), logged under `app.cloud` beside the App's own start failures: such a
    /// refusal never reaches CloudStartChat, so without this the log said nothing at all.
    func cloud(_ start: AgentPaneCloudStart) async -> [String: Any] {
        let reply = await cloudChecked(start)
        if let code = Self.refusedHere(reply) {
            Self.cloudLog.error("cloud start chat refused on this Mac before it reached Cloud (nothing was sent): \(code, privacy: .public)")
        }
        return reply
    }

    /// The codes this pane refuses a start with before the App's start runs, besides `transport.*`:
    /// an attachment Cloud can't take, a pane that can't start one, the send line or another hand-off
    /// still out (`held`), and the tab's one Sandboxed send (`AgentPaneSandboxRuns.refusal`). The page
    /// keeps the same list (webviews cloudStartProgress.ts `REFUSED_HERE`).
    nonisolated static let refusedHereCodes: Set<String> = ["cloud_attachments", "unsupported", "unavailable_now", "sandbox_busy", "sandbox_spent",
                                                             "cloud_folder_missing", "cloud_folder_home", "cloud_folder_secret"]

    /// The reply's code when this pane refused the start itself; nil for a success or the App's own failure.
    nonisolated static func refusedHere(_ reply: [String: Any]) -> String? {
        guard reply["ok"] as? Bool == false, let code = (reply["error"] as? [String: Any])?["code"] as? String else { return nil }
        return code.hasPrefix("transport.") || refusedHereCodes.contains(code) ? code : nil
    }

    private func cloudChecked(_ start: AgentPaneCloudStart) async -> [String: Any] {
        // The folder is a path on this Mac: a chat on another machine never names one to copy.
        guard let run = model.onCloudStartChat, !model.chatIsElsewhere else { return AgentPaneModel.unsupported("cloud.startChat") }
        if let reservationKey = start.reservationKey,
           !model.ownsCloudReservation(reservationKey) {
            // A page cannot attach a lease owned by another compose or pane. The native model is
            // the source of truth for the one live reservation; page state is only a hand-off hint.
            return AgentPaneReply.failure(code: "unavailable_now", message: "unavailable_now")
        }
        guard AgentPaneCloudAttachments(start.attachments) != nil else {
            return AgentPaneReply.failure(code: "cloud_attachments", message: "This attachment needs a local file. Run this chat on This Mac, or paste an image or text to send it to Cloud.")
        }
        // The page names the folder the composer shows as the chat's, and the Send's gesture (`held`)
        // is the person's pick of it, as a typed folder's is for a chat that starts here
        // (AgentPaneTransport `grantTypedFolders`): it need not be one of the tab's roots. The folder,
        // the Git working copy that holds it and that copy's git folders (history, refs) are copied
        // off this Mac, so each must be a real folder that is never home or above it. Leo, on a Cloud
        // start of a folder inside a Git working copy refused as "This folder isn't open in this
        // tab": "what's this". Nil: the App uses the tab's folder.
        var start = start
        start.uploadRoot = nil
        if let cwd = start.cwd {
            let home = model.transport.homeFolder
            let folder: String
            switch await Self.copyableFolder(cwd, home: home) {
            case .success(let checked): folder = checked
            case .failure(let refusal): return refusal.reply
            }
            let root = await Task.detached(priority: .userInitiated) { AgentPaneCloudStart.uploadRoot(of: folder) }.value
            if root != folder {
                switch await Self.copyableFolder(root, home: home) {
                case .success(let checked) where checked == root: break
                case .success: return AgentPaneCloudFolderRefusal.missing.reply
                case .failure(let refusal): return refusal.reply
                }
            }
            let gitFolders = await Task.detached(priority: .userInitiated) { AgentPaneCloudStart.gitFolders(of: root) }.value
            for gitFolder in gitFolders {
                if case .failure(let refusal) = await Self.copyableFolder(gitFolder, home: home) { return refusal.reply }
            }
            start.cwd = folder
            start.uploadRoot = root
        }
        return await held("cloud.startChat", gestureTicket: start.gestureTicket, gestureParams: ["key": start.key]) { [start] replacements in
            let reply = await run(start)
            // A chat that started on the machine keeps the hold: this pane never starts one too,
            // also when the App could not close it.
            if reply["ok"] as? Bool != true { replacements.endSandbox() }
            return reply
        }
    }

    /// `path` canonical when it is a real folder that is not the home folder or above it, and neither
    /// is nor holds one of home's credential folders (``AgentPaneCloudFolderRefusal/secretFolders``);
    /// the refusal otherwise. A Cloud start copies such a folder only on the Send's own gesture (`held`).
    nonisolated static func copyableFolder(_ path: String, home: String?) async -> Result<String, AgentPaneCloudFolderRefusal> {
        await Task.detached(priority: .userInitiated) { () -> Result<String, AgentPaneCloudFolderRefusal> in
            guard let folder = AcpmuxPathPolicy.canonical(path), AcpmuxPathPolicy.isDirectory(folder) else { return .failure(.missing) }
            // No home given: this Mac's own, so the home and credential checks never lapse.
            let home = home ?? NSHomeDirectory()
            let canonicalHome: String? = AcpmuxPathPolicy.canonical(home) ?? (home as NSString).standardizingPath
            guard !AgentHome.isHomeOrAbove(folder, home: canonicalHome) else { return .failure(.homeOrAbove) }
            if let canonicalHome, let secret = AgentPaneCloudFolderRefusal.secretFolder(of: folder, home: canonicalHome) {
                return .failure(.secret("~/" + secret))
            }
            return .success(folder)
        }.value
    }

    /// The shared guards, then `body` with the replacements held (it ends the hold).
    private func held(_ method: String, gestureTicket: String? = nil, gestureParams: [String: Any]? = nil,
                      _ body: @MainActor (AcpmuxPaneReplacements) async -> [String: Any]) async -> [String: Any] {
        guard model.sessionId == nil else { return AgentPaneModel.unsupported(method) }
        let notNow = AgentPaneReply.failure(code: "unavailable_now", message: "unavailable_now")
        let transport = model.transport
        guard await transport.lineDrained(within: .seconds(5)) else { return notNow }
        if let refusal = model.sandboxRuns.refusal { return AgentPaneReply.failure(code: refusal, message: refusal) }
        let replacements = transport.replacements
        guard replacements.beginSandbox() else { return notNow }
        let authorized: Bool
        if let gestureTicket, let connection = transport.connection, let gestureParams {
            authorized = transport.gestures.redeem(gestureTicket, connection: connection, method: method, params: gestureParams)
        } else {
            authorized = transport.gestures.consume()
        }
        guard authorized else {
            replacements.endSandbox()
            return AgentPaneModel.transportFailure(.gestureRequired)
        }
        return await body(replacements)
    }
}

/// Why a Cloud start refused its folder on this Mac, before anything was copied: each has its own
/// code, and the page its own words (webviews `cloudStartProgress.ts` `cloudRefusalText`).
nonisolated enum AgentPaneCloudFolderRefusal: Error, Equatable {
    /// Not a folder on this Mac (gone, or a file).
    case missing
    /// The home folder or a folder above it.
    case homeOrAbove
    /// A credential folder under home, or a folder that holds one: its `~/` spelling.
    case secret(String)

    /// Home's folders of keys and credentials, relative to home, that a Cloud copy never takes, nor a
    /// folder holding one (`~/.config` holds gcloud's, `~/Library` Keychains). cmux-tui's
    /// `link/access_cli.rs` `SECRET_FOLDERS` keeps the like list for a shared folder's files. Never all of
    /// `~/Library`: iCloud Drive and the cloud-storage folders (Dropbox, Google Drive) hold projects there.
    static let secretFolders = [".ssh", ".aws", ".gnupg", ".config/gcloud", ".kube", ".docker", ".secrets", ".azure", "Library/Keychains"]

    /// The first of ``secretFolders`` that `folder` (canonical) is in or holds, by path components; nil
    /// for none. Reads no disk: a credential folder need not exist to be refused.
    static func secretFolder(of folder: String, home: String) -> String? {
        secretFolders.first { relative in
            // By case too: this Mac's disk does not tell `~/.SSH` from `~/.ssh`.
            let secret = (home as NSString).appendingPathComponent(relative).lowercased(), folder = folder.lowercased()
            return AcpmuxPathPolicy.contains(root: secret, path: folder) || AcpmuxPathPolicy.contains(root: folder, path: secret)
        }
    }

    var code: String {
        switch self {
        case .missing: "cloud_folder_missing"
        case .homeOrAbove: "cloud_folder_home"
        case .secret: "cloud_folder_secret"
        }
    }

    /// The reply: the secret's message is the folder's `~/` spelling, which the page's words name.
    var reply: [String: Any] {
        if case .secret(let folder) = self { return AgentPaneReply.failure(code: code, message: folder) }
        return AgentPaneReply.failure(code: code, message: code)
    }
}

extension AgentPaneCloudStart {
    /// The clone row's fields for a seed's or copy's progress line (webviews `cloudStartProgress.ts`):
    /// `progress` (`received_bytes`, `bytes_total`, `objects`, `total_objects`, `files_done`,
    /// `files_total`), and `fallback` and `install_url` when a seed copied instead.
    nonisolated static func fields(_ progress: SeedProgress) -> [String: JSONValue] {
        let numbers: [(String, Int?)] = [("received_bytes", progress.bytesDone), ("bytes_total", progress.bytesTotal),
                                         ("objects", progress.objects), ("total_objects", progress.objectsTotal),
                                         ("files_done", progress.filesDone), ("files_total", progress.filesTotal)]
        var fields: [String: JSONValue] = [:]
        let counts = numbers.compactMap { key, value in value.map { (key, JSONValue.number(Double($0))) } }
        if !counts.isEmpty { fields["progress"] = .object(Dictionary(uniqueKeysWithValues: counts)) }
        if let code = progress.fallbackCode { fields["fallback"] = .string(code) }
        if let url = progress.installURL { fields["install_url"] = .string(url) }
        return fields
    }
}

extension AgentPaneCloudStart {
    /// How this start goes, for the card under the message (webviews `cloudStartProgress.ts`): the
    /// step it is on (`machine`, `folder`, `opening`), the folder it copies, and the machine and its
    /// size once known, keyed by the page's send so a card for another start ignores it.
    @MainActor public func progress(_ step: String, folder: String? = nil, machine: String? = nil, size: String? = nil,
                                    cloneState: String? = nil, clonePhase: String? = nil,
                                    cloneStartedAt: Double? = nil, cloneFinishedAt: Double? = nil,
                                    environmentId: String? = nil, setupState: String? = nil, setupStatus: String? = nil,
                                    setupStartedAt: Double? = nil, setupFinishedAt: Double? = nil,
                                    setupError: String? = nil, setupHasScript: Bool? = nil,
                                    cloneProgress: SeedProgress? = nil, to view: AgentPaneView) {
        var value: [String: JSONValue] = ["key": .string(key), "step": .string(step)]
        if let folder { value["folder"] = .string(folder) }
        if let machine { value["machine"] = .string(machine) }
        if let size { value["size"] = .string(size) }
        var cloneFields: [String: JSONValue] = [:]
        if let cloneState { cloneFields["state"] = .string(cloneState) }
        if let clonePhase { cloneFields["phase"] = .string(clonePhase) }
        if let cloneStartedAt { cloneFields["startedAt"] = .number(cloneStartedAt) }
        if let cloneFinishedAt { cloneFields["finishedAt"] = .number(cloneFinishedAt) }
        if let cloneProgress { cloneFields.merge(Self.fields(cloneProgress)) { $1 } }
        if !cloneFields.isEmpty { value["clone"] = .object(cloneFields) }
        if let environmentId { value["environmentId"] = .string(environmentId) }
        var setupFields: [String: JSONValue] = [:]
        if let setupState { setupFields["state"] = .string(setupState) }
        if let setupStatus { setupFields["status"] = .string(setupStatus) }
        if let setupStartedAt { setupFields["startedAt"] = .number(setupStartedAt) }
        if let setupFinishedAt { setupFields["finishedAt"] = .number(setupFinishedAt) }
        if let setupError { setupFields["error"] = .string(setupError) }
        if let setupHasScript { setupFields["hasScript"] = .bool(setupHasScript) }
        if !setupFields.isEmpty { value["setup"] = .object(setupFields) }
        let push = JSONValue.object(value)
        view.deliver([AgentPageEvent(kind: "cloudStartProgress", value: push)],
                     scripts: ["window.cmuxAcpmuxBridge?.cloudStartProgress?.(\(push.compactText));"])
    }
}
