import CCmuxLayoutReducerFFI
public import CmuxNextDaemon
public import Foundation
public import os
import CmuxNextWakeups

/// The NEXT Cloud start's decisions, asked of Rust (cmux-tui/crates/cmux-cloud-start-core, with
/// their tests) over the app FFI's JSON channel (`cmux_layout_reducer_json`, ops `cloud_*`). The
/// app reads the facts (the policy, the account, the paths, the machine) and acts on the answer;
/// the rules stay in Rust (Leo, 2026-11-02: Cloud logic and its tests belong in Rust, not Swift).
public nonisolated struct CloudStartCore: Sendable {
    public init() {}

    /// One JSON call of the app FFI; nil when it does not answer.
    public func call<Request: Encodable, Reply: Decodable>(_ operation: String, _ request: Request, as: Reply.Type) -> Reply? {
        guard let data = try? JSONEncoder().encode(request), let reply = callData(operation, data) else { return nil }
        return try? JSONDecoder().decode(Reply.self, from: reply)
    }

    /// Calls the app FFI with encoded JSON, returning nil when it cannot answer.
    ///
    /// - Parameter startingCapacity: Initial output bytes; larger replies retry once with the reported size.
    public func callData(_ operation: String, _ data: Data, startingCapacity: Int = 4096) -> Data? {
        guard startingCapacity > 0 else { return nil }
        var capacity = startingCapacity
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity); var outputLength = 0
            let code: Int32 = data.withUnsafeBytes { requestBytes in operation.withCString { operationCString in output.withUnsafeMutableBytes { outputBytes in cmux_layout_reducer_json(requestBytes.bindMemory(to: UInt8.self).baseAddress, data.count, operationCString, outputBytes.bindMemory(to: UInt8.self).baseAddress, outputBytes.count, &outputLength) } } }
            if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, outputLength > capacity {
                capacity = outputLength
                continue
            }
            guard code == CMUX_LAYOUT_REDUCER_OK, outputLength <= capacity else { return nil }
            return Data(output.prefix(outputLength))
        }
        return nil
    }

    // MARK: The start's own checks (`start`)

    /// Whether a send asks the platform for its project's set-up machine (dependencies installed once, then warm): a
    /// personal send, on production only once the sign-in names its platform, since the CLI's default is development.
    /// Leo, 2026-11-06: "we want the default flow to go, the so-called auto mode".
    public func ensuresProject(account: [String?], platform: URL?, production: Bool) -> Bool {
        (account.last ?? nil) == nil && (platform != nil || !production)
    }

    /// Why no Cloud chat can start at all now (`cloud_disabled`, `not_signed_in`), or not yet in the team
    /// the send asked for (`cloud_team_switching`: `requestedTeam` is not `activeTeam`), else nil. An FFI
    /// that does not answer refuses as Cloud off, never a start that goes on unchecked.
    public func refusal(cloudDisabled: Bool, signedIn: Bool, requestedTeam: String? = nil, activeTeam: String? = nil) -> String? {
        struct Request: Encodable { var cloudDisabled: Bool, signedIn: Bool, requestedTeam: String?, activeTeam: String? }
        struct Reply: Decodable { var refusal: String? }
        let request = Request(cloudDisabled: cloudDisabled, signedIn: signedIn, requestedTeam: requestedTeam, activeTeam: activeTeam)
        guard let reply = call("cloud_start_refusal", request, as: Reply.self) else {
            return "cloud_disabled"
        }
        return reply.refusal
    }

    /// Whether a Cloud start that fronts in place keeps the Mac tab's page (`true`: re-homed onto the Cloud
    /// machine, one renderer from Enter to the end) or draws the Cloud tab its own page that replaces it
    /// (cmux-cloud-start-core `one_pane`). On by default; `CMUX_CLOUD_ONE_PANE=0` keeps the swap, as does an
    /// FFI that does not answer.
    public func keepsPage(inPlace: Bool, pageLive: Bool, cloudPageFree: Bool,
                          onePaneEnv: String? = ProcessInfo.processInfo.environment["CMUX_CLOUD_ONE_PANE"]) -> Bool {
        // The wire key stays "killSwitch" (one_pane.rs); the Swift name is not, so check-kill-switches.py reads no reference.
        struct Request: Encodable {
            var inPlace: Bool, pageLive: Bool, cloudPageFree: Bool, onePaneEnv: String?
            enum CodingKeys: String, CodingKey { case inPlace, pageLive, cloudPageFree, onePaneEnv = "killSwitch" }
        }
        struct Reply: Decodable { var shown: String }
        let request = Request(inPlace: inPlace, pageLive: pageLive, cloudPageFree: cloudPageFree, onePaneEnv: onePaneEnv)
        return call("cloud_one_pane", request, as: Reply.self)?.shown == "rehome"
    }

    /// The account a send began in as cmux-tui keeps its sends: its user and team, `/`-joined.
    public func accountText(_ account: [String?]) -> String {
        struct Request: Encodable { var account: [String?] }
        struct Reply: Decodable { var text: String }
        // The FFI not answering keeps the same spelling, so a send is never filed under another account.
        return call("cloud_start_account_text", Request(account: account), as: Reply.self)?.text
            ?? account.map { $0 ?? "" }.joined(separator: "/")
    }

    /// Why a send copies or opens nothing now.
    public enum AccountCheck: String, Sendable, Equatable, Decodable {
        case accountChanged = "account-changed"
        case listUnread = "list-unread"
    }

    /// Nil while a send that began in `asked` may go on with `now` signed in and its list current
    /// (`listCurrent`). An FFI that does not answer stops the send as a list not read.
    public func checkAccount(_ asked: [String?], now: [String?], listCurrent: Bool) -> AccountCheck? {
        struct Request: Encodable { var asked: [String?], now: [String?], listCurrent: Bool }
        struct Reply: Decodable { var check: AccountCheck? }
        guard let reply = call("cloud_start_check_account", Request(asked: asked, now: now, listCurrent: listCurrent), as: Reply.self) else {
            return .listUnread
        }
        return reply.check
    }

    /// What a start does with the machine list it read while it waits for the app's first one.
    public enum ListWait: Sendable, Equatable {
        /// Go on: the list is loaded, or nobody is signed in (that refuses at once).
        case proceed
        /// Pause `ms`, then read the list again when `readAfter`, and ask again.
        case pause(ms: Int, readAfter: Bool)
        /// Still not loaded once the wait is over: the account check refuses it as unread.
        case unread
    }

    /// The step of the wait for the app's first machine list (`list_wait`, the same wait as `cmux cloud
    /// start-chat`'s): `elapsedMs` into the wait, `deadlineLeftMs` of the start's own deadline. An FFI that
    /// does not answer waits no more.
    public func listWait(elapsedMs: Int, deadlineLeftMs: Int? = nil, loaded: Bool, signedIn: Bool) -> ListWait {
        struct Request: Encodable { var elapsedMs: Int, deadlineLeftMs: Int?, loaded: Bool, signedIn: Bool }
        struct Reply: Decodable { var next: String, pauseMs: Int?, readAfter: Bool? }
        let request = Request(elapsedMs: max(elapsedMs, 0), deadlineLeftMs: deadlineLeftMs.map { max($0, 0) }, loaded: loaded, signedIn: signedIn)
        guard let reply = call("cloud_start_list_wait", request, as: Reply.self) else { return .unread }
        switch (reply.next, reply.pauseMs) {
        case ("proceed", _): return .proceed
        case ("pause", let ms?) where ms > 0: return .pause(ms: ms, readAfter: reply.readAfter ?? false)
        default: return .unread
        }
    }

    /// What the chat pane's start does with its failure before the card shows it (`recover::pane_step`, the same
    /// table as `cmux cloud start-chat`'s): start again on its own after `ms`, or show the card.
    public enum PaneRecovery: Sendable, Equatable {
        /// Pause `ms`, then do what the card's Retry does; `cls` is the table's class it ran for, if any.
        case rerun(ms: Int, cls: String?)
        /// Show the card.
        case surface
    }

    /// The pane's step for a failed start: its `code` (empty for none), `message`, whether the card would offer
    /// Retry, how many reruns already ran and the milliseconds since the send began. An FFI that does not answer
    /// shows the card, as before.
    public func paneRecovery(code: String?, message: String, retryable: Bool, reruns: Int, elapsedMs: Int) -> PaneRecovery {
        struct Request: Encodable { var code: String, message: String, retryable: Bool, reruns: Int, elapsedMs: Int }
        struct Reply: Decodable { var next: String, pauseMs: Int?, `class`: String? }
        let request = Request(code: code ?? "", message: message, retryable: retryable, reruns: max(reruns, 0), elapsedMs: max(elapsedMs, 0))
        guard let reply = call("cloud_start_pane_recovery", request, as: Reply.self), reply.next == "rerun", let ms = reply.pauseMs, ms > 0 else { return .surface }
        return .rerun(ms: ms, cls: reply.class)
    }

    /// Whether `root` is the disk's root or the home folder `home` (each as `standardizedFileURL`
    /// spells it): never copied to a machine. An FFI that does not answer counts it too broad.
    public func isTooBroad(root: String, home: String) -> Bool {
        struct Request: Encodable { var root: String, home: String }
        struct Reply: Decodable { var tooBroad: Bool }
        return call("cloud_folder_too_broad", Request(root: root, home: home), as: Reply.self)?.tooBroad ?? true
    }

    /// Whether a start may copy a folder.
    public enum Uploads: String, Sendable, Equatable, Decodable {
        case yes, no
        /// Only when every git folder of the root is inside it: the caller reads the disk for that.
        case ifGitFoldersInside = "if-git-folders-inside"
    }

    /// What a start may copy. `paths`: the root and its canonical path; `homes`: the home folder's
    /// canonical path and the home folder; each standardized (`standardizingPath`). An FFI that does
    /// not answer copies nothing.
    public func uploads(cwdGiven: Bool, uploadRoot: String?, root: String, subpath: String, paths: [String], homes: [String]) -> Uploads {
        struct Request: Encodable { var cwdGiven: Bool, uploadRoot: String?, root: String, subpath: String, paths: [String], homes: [String] }
        struct Reply: Decodable { var uploads: Uploads }
        let request = Request(cwdGiven: cwdGiven, uploadRoot: uploadRoot, root: root, subpath: subpath, paths: paths, homes: homes)
        return call("cloud_start_uploads", request, as: Reply.self)?.uploads ?? .no
    }

    // MARK: Who answers an agent's Cloud ask (`ask`)

    /// A CLI answer to an agent's Cloud ask, read: the card's choice it names, and whether its
    /// caller may give it.
    public struct AskAnswer: Sendable, Equatable {
        public enum Choice: String, Sendable, Equatable, Decodable { case start, notNow }
        /// Nil when the selection names neither Start nor Not now.
        public var choice: Choice?
        /// Whether the caller may give `choice`; false also when only the person may.
        public var allowed: Bool
        /// Whether the caller counts as the person (a CLI request that names no agent session).
        public var person: Bool
    }

    /// Whether a caller with `origin` and `agentSession` (a control request's, or nil) may answer
    /// `selection`, with the person's delegation `delegated` on or off. An FFI that does not answer
    /// takes nothing: the person answers on the card.
    public func askAnswer(origin: String?, agentSession: String?, delegated: Bool, selection: String) -> AskAnswer {
        struct Request: Encodable { var origin: String?, agentSession: String?, delegated: Bool, selection: String }
        struct Reply: Decodable { var caller: String, choice: AskAnswer.Choice?, verdict: String? }
        let request = Request(origin: origin, agentSession: agentSession, delegated: delegated, selection: selection)
        guard let reply = call("cloud_ask_answer", request, as: Reply.self) else { return AskAnswer(choice: nil, allowed: false, person: false) }
        return AskAnswer(choice: reply.choice, allowed: reply.verdict == "allowed", person: reply.caller == "person")
    }

    /// Whether an agent's Cloud start asks the person first; an FFI that does not answer asks.
    public func agentAsksFirst(delegated: Bool) -> Bool {
        struct Request: Encodable { var delegated: Bool }
        struct Reply: Decodable { var asks: Bool }
        return call("cloud_ask_first", Request(delegated: delegated), as: Reply.self)?.asks ?? true
    }

    // MARK: The `vmKind` word (`vm_kind`)

    /// What the Cloud API's caller-relative `vmKind` word grants. Only the exact `owner` owns the
    /// machine and starts its link at the VM boundary; only the exact `team` names a teammate's.
    public struct VmKind: Sendable, Equatable, Decodable {
        public var ownsVm: Bool
        public var teammate: Bool
        public var linkArguments: [String]
    }

    /// The meaning of `vmKind`; an FFI that does not answer grants nothing (the sandbox stays).
    public func vmKind(_ vmKind: String?) -> VmKind {
        struct Request: Encodable { var vmKind: String? }
        return call("cloud_vm_kind", Request(vmKind: vmKind), as: VmKind.self) ?? VmKind(ownsVm: false, teammate: false, linkArguments: [])
    }
}

/// The composer's Cloud send as a hybrid start: its first turn runs on this Mac while the Cloud
/// machine boots, then the chat moves there with the app's own Move (fenced, cmux#55785). Every
/// decision is cmux-cloud-start-core `hybrid_gui` (FFI `cloud_hybrid_gui_start`); this only passes
/// the facts, logs the probe line (`cloud hybrid gui start: here` or `... off <reason>`) and runs
/// `cmux cloud hybrid-begin SESSION new` once the chat here has its session. Kill switches:
/// `CMUX_HYBRID_START=0`, `CMUX_GUI_HYBRID_START=0` (read by the FFI).
public nonisolated struct CloudHybridGUIStart {
    public nonisolated init() {}
    /// What the app knows of its Cloud send (cmux-cloud-start-core `hybrid_gui::Send`).
    public struct Send: Sendable {
        public var plan: String?, signedIn: Bool, cloudDisabled: Bool
        public var folder: Bool, repository: Bool, team: Bool, replacesChat: Bool, environment: Bool
        public var harness: String?
        /// This Mac's acpmux `_acpmux/harnesses` answer, JSON; nil: it did not answer.
        public var catalog: Data?
        public init(plan: String?, signedIn: Bool, cloudDisabled: Bool, folder: Bool, repository: Bool, team: Bool,
                    replacesChat: Bool, environment: Bool, harness: String?, catalog: Data?) {
            self.plan = plan; self.signedIn = signedIn; self.cloudDisabled = cloudDisabled; self.folder = folder
            self.repository = repository; self.team = team; self.replacesChat = replacesChat
            self.environment = environment; self.harness = harness; self.catalog = catalog
        }
    }

    /// Whether the send runs its first turn here; logs Rust's probe line either way.
    public static func runsHere(_ send: Send, logger: Logger) -> Bool {
        var request: [String: Any] = [
            "account": ["plan": send.plan as Any, "signedIn": send.signedIn, "cloudDisabled": send.cloudDisabled],
            "folder": send.folder, "repository": send.repository, "team": send.team,
            "replacesChat": send.replacesChat, "environment": send.environment,
        ]
        if let harness = send.harness { request["harness"] = harness }
        if let catalog = send.catalog, let object = try? JSONSerialization.jsonObject(with: catalog) { request["catalog"] = object }
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let reply = CloudStartCore().callData("cloud_hybrid_gui_start", data),
              let answer = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] else {
            logger.notice("cloud hybrid gui start: unanswered")
            return false
        }
        logger.notice("\((answer["probe"] as? String) ?? "cloud hybrid gui start: unanswered", privacy: .public)")
        return answer["here"] as? Bool == true
    }

    /// Begins the machine and the move for `session`, the chat here: the CLI's own detached driver.
    public static func begin(session: String, cli: URL, logger: Logger) {
        // task-owner: fire and forget; the CLI returns once its detached driver is spawned (30 s bound)
        Task(priority: WorkPriority.bestEffort.taskPriority) {
            let result = try? await ProcessRunner.run(executable: cli, arguments: ["cloud", "hybrid-begin", session, "new"],
                                                      environment: nil, timeout: .seconds(30), clock: ContinuousClock())
            let said = result.map { String(decoding: $0.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "not run"
            logger.notice("cloud hybrid gui start: begun \(session, privacy: .public) status \(result?.status ?? -1) \(said, privacy: .public)")
        }
    }
}
