public import CmuxNextCloud
import CmuxNextCompat
public import CmuxNextSettings
public import Foundation
import os

/// `cloud.startChat {task, cwd?, harness?, model?, mode?, key}`: a new chat's first send with Cloud picked
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
    /// The permission mode the person picked for the chat before its first send; nil: the machine's
    /// own start mode. The chat's machine applies it only when it is the caller's own (``seed(cwd:draft:)``).
    public var mode: String?
    /// The selected Cloud environment id; nil lets workspace ensure resolve personal Default.
    public var environment: String?
    /// The warm machine reserved by this compose; Send binds it using ``key``.
    public var reservationKey: String?
    /// Native Send authorization reserved before waiting for the speculative lease.
    var gestureTicket: String?
    /// The page's send again after its `cloud.signIn` signed in: authorized only by
    /// the click that sign-in kept for this ``key`` (``AgentPaneModel/takeCloudSignInGrant(_:)``), never a gesture.
    var signedIn = false
    /// The team to switch to before this send (the plan card's Switch to <team>): a team id of the
    /// person's, switched to by the App as the team picker does; nil keeps the active team.
    public var team: String?
    /// The page's send: a second call with the same key while one runs is the same send.
    public var key: String
    /// The folder the copy uploads (the Git working copy that holds ``cwd``, else ``cwd``), set by
    /// the pane once it checked that folder against its roots too (``AgentPaneHandOff``); nil when
    /// the page named no folder. The App copies only this folder, never one it finds anew.
    public var uploadRoot: String?
    /// The Mac files this send's link chips may carry to the machine, set by the pane from what it
    /// authorized itself (``AgentPaneModel/cloudCarriedFiles(_:)``); never read from the page.
    public var carriedFiles: Set<String> = []
    /// Those of ``carriedFiles`` this app saved under Chat Uploads (in `~/Library`, which the upload
    /// CLI never reads from): cloned into the private paste folder first, as image copies are. Only
    /// app-owned files are staged: a staged copy no longer carries the CLI's folder rules.
    public var stagedFiles: Set<String> = []

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
              let harness = name("harness"), let model = name("model"), let environment = name("environment"),
              let team = name("team"), let mode = name("mode") else { return nil }
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
        self.team = team
        self.mode = mode
        self.attachments = attachments
        let signedIn = params?["signedIn"]
        if let signedIn, !(signedIn is Bool) { return nil }
        self.signedIn = signedIn as? Bool ?? false
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
    /// prompt, sent once with the Send's gesture, on the agent and model the page picked. `draft`: what
    /// the sending tab's composer held when the chat opened (typed after the Send), shown, never sent.
    public func seed(cwd: String?, draft: String? = nil) -> AgentPaneSeed {
        AgentPaneSeed(cwd: cwd, draft: draft, prompt: task, promptAttachments: attachments.isEmpty ? nil : attachments,
                      promptBy: .person, harness: harness, model: model, mode: mode)
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

    /// The most a Cloud start or Sandboxed send waits for the send line, while it moves.
    nonisolated static let lineDrainLimit: Duration = .seconds(60)

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
        // A Send without the reservation: one still out is this pane's to release as it answers.
        if start.reservationKey == nil { model.dropCloudReservation() }
        var start = start
        (start.carriedFiles, start.stagedFiles) = await model.cloudCarriedFiles(start.attachments)
        guard AgentPaneCloudAttachments(start.attachments, files: start.carriedFiles, staged: start.stagedFiles) != nil else {
            return AgentPaneReply.failure(code: "cloud_attachments", message: AgentPaneCloudAttachments.refusal(start.attachments))
        }
        // The page names the folder the composer shows as the chat's, and the Send's gesture (`held`)
        // is the person's pick of it, as a typed folder's is for a chat that starts here
        // (AgentPaneTransport `grantTypedFolders`): it need not be one of the tab's roots. The folder,
        // the Git working copy that holds it and that copy's git folders (history, refs) are copied
        // off this Mac, so each must be a real folder that is never home or above it. Leo, on a Cloud
        // start of a folder inside a Git working copy refused as "This folder isn't open in this
        // tab": "what's this". Nil: the App uses the tab's folder.
        start.uploadRoot = nil
        if let cwd = start.cwd {
            switch await AgentPaneCloudStart.checkedFolder(cwd, home: model.transport.homeFolder) {
            case .success(let checked):
                start.cwd = checked.folder
                start.uploadRoot = checked.root
            case .failure(let refusal): return refusal.reply
            }
        }
        // The send again after a sign-in: the click that sign-in kept for this key authorizes it,
        // taken in `held` right before `run`, so a `cloud.signInCancel` the page sent first always wins.
        let grantKey = start.signedIn ? start.key : nil
        return await held("cloud.startChat", gestureTicket: start.gestureTicket, gestureParams: ["key": start.key],
                          signInGrant: grantKey) { [start] replacements in
            let reply = await run(start)
            // A chat that started on the machine keeps the hold: this pane never starts one too,
            // also when the App could not close it.
            if reply["ok"] as? Bool != true { replacements.endSandbox() }
            return reply
        }
    }

    /// The shared guards, then `body` with the replacements held (it ends the hold).
    /// `signInGrant`: the start's key, authorized only by the click its sign-in kept (no gesture);
    /// without that click (withdrawn, spent or stale) the send is `cloud_sign_in_cancelled`.
    private func held(_ method: String, gestureTicket: String? = nil, gestureParams: [String: Any]? = nil, signInGrant: String? = nil,
                      _ body: @MainActor (AcpmuxPaneReplacements) async -> [String: Any]) async -> [String: Any] {
        guard model.sessionId == nil else { return AgentPaneModel.unsupported(method) }
        let notNow = AgentPaneReply.failure(code: "unavailable_now", message: "unavailable_now")
        let transport = model.transport
        // A start waits for the line while it moves (a busy daemon sends slowly); a fixed 5 s refused
        // a slow but working line as `unavailable_now`. A line that stops moving still refuses.
        guard await transport.lineDrained(quiet: .seconds(5), limit: Self.lineDrainLimit) else { return notNow }
        if let refusal = model.sandboxRuns.refusal { return AgentPaneReply.failure(code: refusal, message: refusal) }
        let replacements = transport.replacements
        guard replacements.beginSandbox() else { return notNow }
        let authorized: Bool
        if let signInGrant {
            // No await from here to `body`'s `run`: the check and the start are one turn.
            guard model.takeCloudSignInGrant(signInGrant) else {
                replacements.endSandbox()
                return AgentPaneReply.failure(code: "cloud_sign_in_cancelled", message: "cloud_sign_in_cancelled")
            }
            authorized = true
        } else if let gestureTicket, let connection = transport.connection, let gestureParams {
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

extension AgentPaneModel {
    /// `cloud.signIn {key}`: the Cloud start card's Sign in, on its click. Signs the app's Cloud account
    /// in (no browser when it already is, in another pane, window or Settings) and keeps the click for
    /// the page's one send again of start `key` (`cloud.startChat {..., signedIn: true}`). The page owns
    /// the rest: the card's waiting state, the wait's deadline and its cancel (webviews cloudSignIn.ts).
    func signInToCloud(key: String) async -> [String: Any] {
        guard onCloudStartChat != nil, !chatIsElsewhere, sessionId == nil else { return Self.unsupported("cloud.signIn") }
        guard transport.gestures.consume() else { return Self.transportFailure(.gestureRequired) }
        let generation = cloudSignInGeneration
        var signedIn = onCloudSignedIn?() == true
        if !signedIn, let signIn = onCloudSignIn {
            // One browser sign-in per pane: a click after a cancel, while that browser is still open,
            // waits on it again; a second `auth.signIn()` would end it and lose its progress.
            let browser = cloudSignInBrowser ?? Task { @MainActor in await signIn() }
            cloudSignInBrowser = browser
            signedIn = await browser.value
            if cloudSignInBrowser == browser { cloudSignInBrowser = nil }
        }
        guard signedIn else { return AgentPaneReply.failure(code: "not_signed_in", message: "Sign in to continue") }
        // The page left Cloud or gave up meanwhile: the sign-in stands, but no click is kept.
        guard cloudSignInGeneration == generation else {
            return AgentPaneReply.failure(code: "cloud_sign_in_cancelled", message: "cloud_sign_in_cancelled")
        }
        keepCloudSignInGrant(key, generation: generation)
        return AgentPaneReply.success(["signedIn": true])
    }

    /// `cloud.signInCancel {expired?}`: the page stopped waiting on a `cloud.signIn` (it left Cloud, or
    /// its deadline passed), so the kept click goes and a sign-in still out keeps none. An expired one
    /// also ends its browser sign-in (the App's sign-in ends its auth attempt on that), so the card's
    /// Sign in again opens a fresh one instead of waiting on the abandoned one.
    func cancelCloudSignIn(expired: Bool) -> [String: Any] {
        cloudSignInGeneration += 1
        cloudSignInGrant = nil
        if expired {
            cloudSignInBrowser?.cancel()
            cloudSignInBrowser = nil
        }
        return AgentPaneReply.success()
    }

    /// How long a sign-in's kept click waits for the page's send again; the page sends it at once.
    nonisolated static let cloudSignInGrantLifetime: Duration = .seconds(30)

    /// Keeps the click of a `cloud.signIn` that signed in, for one send again of the start `key`
    /// while ``cloudSignInGeneration`` is still `generation`.
    func keepCloudSignInGrant(_ key: String, generation: Int) {
        cloudSignInGrant = (key, generation, ContinuousClock.now.advanced(by: Self.cloudSignInGrantLifetime))
    }

    /// Takes the kept click for the start `key`: true once, only while no `cloud.signInCancel` came
    /// since its sign-in and within its lifetime. Any try spends it.
    func takeCloudSignInGrant(_ key: String) -> Bool {
        guard let grant = cloudSignInGrant else { return false }
        cloudSignInGrant = nil
        return grant.key == key && grant.generation == cloudSignInGeneration && ContinuousClock.now < grant.until
    }
}
