import CCmuxLayoutReducerFFI
public import Foundation

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

    /// Why no Cloud chat can start at all now (`cloud_disabled`, `not_signed_in`), else nil. An FFI
    /// that does not answer refuses as Cloud off, never a start that goes on unchecked.
    public func refusal(cloudDisabled: Bool, signedIn: Bool) -> String? {
        struct Request: Encodable { var cloudDisabled: Bool, signedIn: Bool }
        struct Reply: Decodable { var refusal: String? }
        guard let reply = call("cloud_start_refusal", Request(cloudDisabled: cloudDisabled, signedIn: signedIn), as: Reply.self) else {
            return "cloud_disabled"
        }
        return reply.refusal
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
