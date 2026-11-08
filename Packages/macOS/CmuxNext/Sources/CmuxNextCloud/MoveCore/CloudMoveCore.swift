public import Foundation

/// Move to Cloud's, Bring Back Local's and a chat start's rules, asked of Rust
/// (cmux-tui/crates/cmux-cloud-start-core `moves`, with their tests) over the app FFI's JSON
/// channel (ops `cloud_move_*`), through ``CloudStartCore/call(_:_:as:)``. The app runs the CLIs
/// and git, reads its defaults and the disk, observes its main-actor state, and acts on the answer.
public nonisolated struct CloudMoveCore: Sendable {
    public init() {}

    /// One `cloud_move_*` op; nil when the FFI does not answer.
    public func call<Request: Encodable, Reply: Decodable>(_ operation: String, _ request: Request, as: Reply.Type) -> Reply? {
        CloudStartCore().call("cloud_move_" + operation, request, as: Reply.self)
    }

    /// The waits' deadlines (`moves::wait::DEADLINES`). An FFI that does not answer waits for
    /// nothing: a wait ends at once rather than hold a start forever.
    public struct Deadlines: Sendable, Decodable {
        public var startRedialInitialMs = 0, startRedialMaximumMs = 0, relinkMs = 0, workspaceTreeMs = 0, runKeptMs = 0, runsKept = 0
        public init() {}
    }

    public static let deadlines: Deadlines = CloudMoveCore().call("deadlines", [String: String](), as: Deadlines.self) ?? Deadlines()

    /// Whether a machine's link came back after an update restarted its daemon: its handshake key
    /// is there and differs from `before`; `refused` counts only with `refusedCounts`.
    public func relinked(before: String?, now: String?, refusedCounts: Bool) -> Bool {
        struct Request: Encodable { var before: String?, now: String?, refusedCounts: Bool }
        struct Reply: Decodable { var relinked: Bool }
        return call("relinked", Request(before: before, now: now, refusedCounts: refusedCounts), as: Reply.self)?.relinked ?? false
    }

    /// Whether an answer is the machine's older daemon refusing it (`machine_outdated`, not `side` `source`).
    public func updatesBeforeCopyingAgain(ok: Bool, errorCode: String?, side: String?) -> Bool {
        struct Request: Encodable { var ok: Bool, errorCode: String?, side: String? }
        struct Reply: Decodable { var updates: Bool }
        return call("outdated_refusal", Request(ok: ok, errorCode: errorCode, side: side), as: Reply.self)?.updates ?? false
    }
}

/// Whether a loaded Cloud machine list still answers for `account`: loaded for it, less than `age` ago (Rust's rule).
public nonisolated struct CloudListFreshness {
    public nonisolated init() {}
    public static func isCurrent(loadedAt: ContinuousClock.Instant?, loadedFor: [String?]?, account: [String?], now: ContinuousClock.Instant, within age: Duration) -> Bool {
        struct Request: Encodable { var loadedAgoMs: UInt64?, loadedFor: [String?]?, account: [String?], withinMs: UInt64 }
        struct Reply: Decodable { var current: Bool }
        let ago = loadedAt.map { UInt64(max(0, $0.duration(to: now).wholeMilliseconds)) }
        let request = Request(loadedAgoMs: ago, loadedFor: loadedFor, account: account, withinMs: UInt64(max(0, age.wholeMilliseconds)))
        return CloudMoveCore().call("list_current", request, as: Reply.self)?.current ?? false
    }
}

/// Answers every redirect with "do not follow" (completion-handler form).
public nonisolated final class CloudRefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    override public init() {}

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

extension Duration {
    /// Whole milliseconds, rounded down.
    nonisolated var wholeMilliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }
}

extension CloudStartCore {
    /// Whether a Cloud start that is not an agent chat's starts as the person's Start would: their gesture
    /// (`byPerson`) or any run while they let agents start without asking (`delegated`). Leo, 2026-11-04:
    /// "it had this prompt idk if we want that". An FFI that does not answer asks.
    public func startsAsPerson(byPerson: Bool, delegated: Bool) -> Bool {
        struct Request: Encodable { var byPerson: Bool, delegated: Bool }
        struct Reply: Decodable { var person: Bool }
        return CloudMoveCore().call("starts_as_person", Request(byPerson: byPerson, delegated: delegated), as: Reply.self)?.person ?? byPerson
    }

    /// A personal send on a non-production sign-in copies through the content-addressed store.
    public func copiesThroughStore(account: [String?], productionAuth: Bool) -> Bool {
        struct Request: Encodable { var account: [String?], productionAuth: Bool }
        struct Reply: Decodable { var store: Bool }
        return CloudMoveCore().call("copies_through_store", Request(account: account, productionAuth: productionAuth), as: Reply.self)?.store ?? false
    }

    /// `text` as one shell word. An FFI that does not answer quotes it.
    public static func shellQuoted(_ text: String) -> String {
        struct Request: Encodable { var text: String }
        struct Reply: Decodable { var word: String }
        return CloudMoveCore().call("shell_quoted", Request(text: text), as: Reply.self)?.word
            ?? "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The plan's request (`cmux link start-chat plan --request`): the send's key, account and Mac workspace, who
    /// is signed in, the machines the account's list named, the store's others (`stored`), and the chat's folder,
    /// environment and token flag (`access`).
    public func planRequest(key: String, account: [String?], workspace: String?, user: String?, machines: [[String: Any]],
                            local: String? = nil, stored: [String], environment: String? = nil, access: Bool = false,
                            reservationKey: String? = nil, platform: String? = nil, team: String? = nil, ensureProject: Bool? = nil) -> String {
        let facts: [String: Any?] = ["key": key, "account": account.map { $0.map { $0 as Any } ?? NSNull() }, "workspace": workspace, "user": user,
                                     "machines": machines, "local": local, "stored": stored, "environment": environment, "access": access,
                                     "reservationKey": reservationKey, "platform": platform, "team": team, "ensureProject": ensureProject]
        guard let data = try? JSONSerialization.data(withJSONObject: facts.compactMapValues { $0 }),
              let reply = callData("cloud_move_plan_request", data),
              let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              let request = object["request"] as? String else { return "{}" }
        return request
    }
}

extension CloudMachineRequest {
    /// The create of the machine for a send: sized for the chat, under the send's own idempotency key
    /// (the plan's `create_key`), so a retry after a create whose answer was lost gets the same
    /// machine from the server, never a second paid VM. Its team is the send's, fixed for every try.
    public init(startChatKey key: String, sizedFor pick: CloudWorkPick?, team: String?) {
        self.init()
        autosize = pick?.autosize
        idempotencyKey = key
        self.team = team
    }
}
