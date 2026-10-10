import CmuxNextAgentActivity
import CmuxNextAgentPane
import CmuxNextFeed
import CmuxNextWakeups
import CryptoKit
import Foundation
import os

/// The feed bridge for agent permission prompts (cx-aocz, D11 on
/// manaflow-ai/cmux#13742): the person answers an acpmux prompt on the phone,
/// this Mac app answers acpmux for them.
///
/// - Its own acpmux connection presents this launch's person key in its first
///   `initialize` (acpmux `hub/person.rs`), then watches every session. It is
///   not the agent pane's relay: no page frame ever reaches it.
/// - Each pending prompt becomes one feed `approve` request (tool, the exact
///   command, a short input summary; secret shapes scrubbed, env never sent).
///   The ids of the items it posted are kept in memory for this launch only:
///   a look-alike item another local client posted through `feed.request` is
///   never trusted, whatever its poster says.
/// - An answer counts only when the feed owner accepted it from the person's
///   own client (feed.answer is user-only, same account, origin user) AND its
///   authenticated `by` is an install that is not this Mac's own install. A
///   session answer (`session:<user>`, which a browser or a process on this
///   Mac could hold) answers nothing.
/// - Before it answers, it re-reads the prompt: still pending, the same request
///   (sha256 of its canonical JSON), and the option the decision maps to is
///   offered. Allow maps to the offered `allow_once` option, deny to the
///   offered reject option. Then `_acpmux/permission_respond` with
///   `answeredBy {device: <by>, feedItem: <id>}`. An expired, cancelled or
///   already closed prompt answers nothing.
///
/// Residual risks (named in cx-aocz): a DEV ad-hoc build keeps the Stack
/// session in a plain file (Keychain is unavailable) and ~/.secrets holds the
/// dogfood Stack password, so in DEV a Mac-side agent could register its own
/// "ios" install and answer: DEV is not device-bound. A browser session on this
/// Mac driven by a Mac-side agent is a session answer and is refused here; the
/// CUA and dialog rules cover what else such an agent could do.
@MainActor
final class AcpmuxPermissionFeedBridge {

    /// What one posted feed item stands for.
    struct Posted: Equatable {
        let session: String
        let permission: String
        let digest: String
        /// sha256 of the shown text this Mac posted (FeedApproveShownText):
        /// what the phone's proof must cover.
        let shown: String
    }

    /// This Mac's context and the owner's presence keys, read fresh for each
    /// allow (FeedApproveProofCheck).
    typealias PresenceKeys = @MainActor () async throws
        -> (context: FeedApproveProofCheck.Context, keys: [String: FeedApproveProofCheck.Key])

    /// One feed call to the API Worker as the signed-in person.
    typealias Owner = @MainActor (_ path: String, _ body: [String: Any]) async throws -> [String: Any]

    private let socket: String
    private let owner: Owner
    private let isSignedIn: @MainActor () -> Bool
    /// This Mac's own install id (the `inst` claim of its install token).
    private let ownInstall: @Sendable () async -> String?
    /// An allow counts only with a valid signature by a key that only the
    /// person's real phone holds (cx-aocz: an App-Attested presence key).
    /// Install kind alone is not proof of a phone: a process with the user's
    /// session can register an "ios" install. A deny needs no proof.
    private let presenceKeys: PresenceKeys
    private var connection: AgentActivityLineConnection?
    private var reconnect: Task<Void, Never>?
    private var backoff = Backoff(initial: .milliseconds(500), maximum: .seconds(30))
    private var nextID = 10
    private var replies: [Int: CheckedContinuation<[String: Any]?, Never>] = [:]
    /// Feed item id -> the prompt it carries. This launch only.
    private(set) var posted: [String: Posted] = [:]
    /// Permission ids being posted or posted (one item per prompt).
    private var postedPermissions: Set<String> = []
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "acpmux.feed-bridge")

    init(socketPath: String, owner: @escaping Owner, isSignedIn: @escaping @MainActor () -> Bool,
         ownInstall: @escaping @Sendable () async -> String?,
         presenceKeys: @escaping PresenceKeys) {
        socket = socketPath
        self.owner = owner
        self.isSignedIn = isSignedIn
        self.ownInstall = ownInstall
        self.presenceKeys = presenceKeys
    }

    /// Starts the watch (idempotent).
    func start() {
        guard connection == nil, reconnect == nil else { return }
        connect()
    }

    isolated deinit {
        reconnect?.cancel()
        connection?.cancel()
    }

    // MARK: acpmux

    private func connect() {
        reconnect = nil
        guard FileManager.default.fileExists(atPath: socket) else { return scheduleReconnect() }
        let line = AgentActivityLineConnection(path: socket)
        connection = line
        line.start(send: Self.hello,
                   onLine: { [weak self] data in Task { @MainActor in self?.handle(data) } },
                   onClose: { [weak self] in Task { @MainActor in self?.lost(line) } })
    }

    /// `initialize` with this launch's person key (the connection's first
    /// request), then `_acpmux/watch` over every session.
    static var hello: Data {
        let initialize = AcpmuxEnvironment.withPersonKey([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": 1, "clientInfo": ["name": "cmux-next-feed-bridge", "version": "1"],
                       "clientCapabilities": [String: Any]()],
        ])
        let watch: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "_acpmux/watch", "params": ["enabled": true]]
        var payload = Data()
        for request in [initialize, watch] {
            payload += (try? JSONSerialization.data(withJSONObject: request)) ?? Data()
            payload.append(0x0A)
        }
        return payload
    }

    private func lost(_ line: AgentActivityLineConnection) {
        guard connection === line else { return }
        connection = nil
        for (_, waiter) in replies { waiter.resume(returning: nil) }
        replies = [:]
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnect?.cancel()
        // task-owner: AcpmuxPermissionFeedBridge.reconnect: one backoff wait after a lost or absent socket.
        reconnect = Task { [weak self] in
            guard var backoff = self?.backoff else { return }
            // concurrency-allow: Backoff.wait is an async sleep after a failure, not a blocking wait.
            do { try await backoff.wait(owner: "acpmux-feed-bridge.reconnect") } catch { return }
            self?.backoff = backoff
            self?.connect()
        }
    }

    /// One request on the bridge's own connection; nil when it closed or failed.
    private func call(_ method: String, _ params: [String: Any]) async -> [String: Any]? {
        guard let connection else { return nil }
        nextID += 1
        let id = nextID
        let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        guard var data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        data.append(0x0A)
        return await withCheckedContinuation { waiter in
            replies[id] = waiter
            connection.send(data)
        }
    }

    private func handle(_ data: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = (message["id"] as? NSNumber)?.intValue {
            if id == 1 {
                let person = ((message["result"] as? [String: Any])?["_meta"] as? [String: Any])
                    .flatMap { ($0["acpmux"] as? [String: Any])?["person"] as? Bool } ?? false
                if !person { logger.error("feed bridge: acpmux did not accept this launch's person key; phone answers stay refused") }
            } else if id == 2, let result = message["result"] as? [String: Any] {
                backoff.reset()
                // Prompts that were pending before this connection.
                for summary in result["sessions"] as? [[String: Any]] ?? []
                    where (summary["pendingPermissions"] as? NSNumber)?.intValue ?? 0 > 0 {
                    if let session = summary["sessionId"] as? String { Task { await self.postPending(of: session) } }
                }
            } else if let waiter = replies.removeValue(forKey: id) {
                waiter.resume(returning: message["error"] == nil ? (message["result"] as? [String: Any] ?? [:]) : nil)
            }
            return
        }
        guard let method = message["method"] as? String, let params = message["params"] as? [String: Any] else { return }
        switch method {
        case "_acpmux/permission_pending":
            guard let session = params["sessionId"] as? String, let permission = params["permissionId"] as? String,
                  let request = params["request"] as? [String: Any] else { return }
            Task { await self.post(session: session, permission: permission, request: request) }
        case "_acpmux/session_changed":
            let kind = params["kind"] as? String
            if kind == "permission_decision" || kind == "permission_resolved",
               let session = params["sessionId"] as? String {
                Task { await self.withdrawResolved(in: session) }
            }
        default:
            break
        }
    }

    /// The pending prompts of `session`, from `_acpmux/info`.
    private func pending(of session: String) async -> [[String: Any]] {
        (await call("_acpmux/info", ["sessionId": session]))?["pending"] as? [[String: Any]] ?? []
    }

    private func postPending(of session: String) async {
        for entry in await pending(of: session) {
            guard let permission = entry["permissionId"] as? String, let request = entry["request"] as? [String: Any] else { continue }
            await post(session: session, permission: permission, request: request)
        }
    }

    // MARK: Feed

    /// sha256 of the request's canonical JSON (sorted keys).
    nonisolated static func digest(_ request: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The feed.post body for one prompt: what the person must see to decide.
    nonisolated static func postBody(session: String, permission: String, request: [String: Any]) -> [String: Any] {
        let call = request["toolCall"] as? [String: Any] ?? [:]
        let title = FeedSecretScrubber.scrub(call["title"] as? String ?? "")
        let kind = call["kind"] as? String ?? ""
        let input = call["rawInput"] as? [String: Any] ?? [:]
        let command = (input["command"] as? String).map(FeedSecretScrubber.scrub)
        var action: [String: Any] = [
            "type": kind == "execute" ? "command" : kind == "edit" || kind == "delete" || kind == "move" ? "edit" : "tool",
            "summary": cut(title.isEmpty ? String(localized: "feed.bridge.summary", defaultValue: "An agent asks to run a tool", bundle: .module) : title, 500),
        ]
        if !kind.isEmpty { action["tool"] = cut(kind, 200) }
        if let command, !command.isEmpty { action["command"] = cut(command, 8000) }
        if let summary = inputSummary(input), command == nil { action["input"] = summary }
        let key = "acpmux:\(permission)"
        let heading = String(localized: "feed.bridge.title", defaultValue: "Allow \(cut(title.isEmpty ? kind : title, 120))?", bundle: .module)
        var params: [String: Any] = [
            "type": "request",
            "kind": "approve",
            "title": cut(heading, 200),
            "prompt": ["action": action, "scopes": ["once"]],
            "dedupe_key": String(key.prefix(200)),
            "thread": String("acpmux:\(session)".prefix(200)),
            "poster": ["label": String(localized: "feed.bridge.poster", defaultValue: "Agent", bundle: .module)],
        ]
        if let command, !command.isEmpty { params["body"] = cut(command, 4096) }
        return ["op": "feed.post", "params": params, "idempotency_key": String(key.prefix(200)), "origin": "script"]
    }

    /// A short, scrubbed summary of a tool input without a command: field names
    /// with short string values (paths, patterns); nothing that looks like env.
    nonisolated static func inputSummary(_ input: [String: Any]) -> [String: String]? {
        var out: [String: String] = [:]
        for (key, value) in input.sorted(by: { $0.key < $1.key }).prefix(8) where key.lowercased() != "env" {
            if let text = value as? String { out[cut(key, 40)] = cut(FeedSecretScrubber.scrub(text), 200) }
        }
        return out.isEmpty ? nil : out
    }

    private func post(session: String, permission: String, request: [String: Any]) async {
        guard isSignedIn(), postedPermissions.insert(permission).inserted else { return }
        do {
            let body = Self.postBody(session: session, permission: permission, request: request)
            let reply = try await owner("v1/ops", body)
            guard let id = ((reply["value"] as? [String: Any])?["item"] as? [String: Any])?["id"] as? String else {
                postedPermissions.remove(permission)
                return logger.error("feed bridge: the owner returned no item for \(permission, privacy: .public)")
            }
            let action = ((body["params"] as? [String: Any])?["prompt"] as? [String: Any])?["action"] as? [String: Any] ?? [:]
            posted[id] = Posted(session: session, permission: permission, digest: Self.digest(request),
                                shown: FeedApproveProofCheck.shownSHA256(action: action))
            logger.info("feed bridge: posted \(id, privacy: .public) for \(permission, privacy: .public)")
        } catch {
            postedPermissions.remove(permission)
            logger.error("feed bridge: post failed for \(permission, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// The prompt was answered or ended elsewhere: the person no longer needs
    /// the feed item.
    private func withdrawResolved(in session: String) async {
        let open = posted.filter { $0.value.session == session }
        guard !open.isEmpty else { return }
        let still = Set(await pending(of: session).compactMap { $0["permissionId"] as? String })
        for (item, entry) in open where !still.contains(entry.permission) {
            posted[item] = nil
            let body: [String: Any] = ["op": "feed.cancel", "params": ["item": item, "reason": "answered_elsewhere"],
                                       "idempotency_key": "cancel:\(item)", "origin": "script"]
            _ = try? await owner("v1/ops", body)
        }
    }

    /// The feed mirror changed: answer for every item this launch posted that
    /// the person answered.
    func itemsChanged(_ items: [FeedItem]) {
        for item in items where item.state != .open {
            guard let entry = posted.removeValue(forKey: item.id) else { continue }
            guard let answer = item.answer, case .approve(let decision) = answer.value else {
                logger.info("feed bridge: \(item.id, privacy: .public) closed without an answer; nothing answered")
                continue
            }
            Task { await self.answer(item: item.id, entry: entry, decision: decision, record: answer) }
        }
    }

    enum Refusal: Error, Equatable {
        case sessionAnswer
        case ownInstall
        case byNotPlain
        case notPending
        case changed
        case notOffered
        case scope
    }

    /// The acpmux option a decision maps to, from what the prompt offers now.
    nonisolated static func option(for decision: FeedAnswerValue.Decision, offered: [[String: Any]]) -> Result<String, Refusal> {
        if decision.outcome == .allow, let scope = decision.scope, scope != .once { return .failure(.scope) }
        let kinds = decision.outcome == .allow ? ["allow_once"] : ["reject_once", "reject_always"]
        for kind in kinds {
            let matches = offered.filter { $0["kind"] as? String == kind }
            if matches.count == 1, let id = matches[0]["optionId"] as? String { return .success(id) }
        }
        return .failure(.notOffered)
    }

    /// Whether `by` may answer for the person here: an install (not a session)
    /// that is not this Mac's own install.
    nonisolated static func admits(by: String, ownInstall: String?) -> Result<Void, Refusal> {
        if by.hasPrefix("session:") { return .failure(.sessionAnswer) }
        if let ownInstall, by == ownInstall { return .failure(.ownInstall) }
        let plain = (1...128).contains(by.count)
            && by.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "_.:-".unicodeScalars.contains($0) }
        return plain ? .success(()) : .failure(.byNotPlain)
    }

    private func answer(item: String, entry: Posted, decision: FeedAnswerValue.Decision, record: FeedAnswerRecord) async {
        let (by, device) = (record.by, record.device)
        let own = await ownInstall()
        if case .failure(let refusal) = Self.admits(by: by, ownInstall: own) {
            return logger.error("feed bridge: \(item, privacy: .public) answered by \(by, privacy: .public) (\(device, privacy: .public)) refused: \(String(describing: refusal), privacy: .public)")
        }
        guard let now = await pending(of: entry.session).first(where: { $0["permissionId"] as? String == entry.permission }),
              let request = now["request"] as? [String: Any] else {
            return logger.info("feed bridge: \(item, privacy: .public) answered after the prompt ended; nothing answered")
        }
        guard Self.digest(request) == entry.digest else {
            return logger.error("feed bridge: \(item, privacy: .public): the prompt changed since it was posted; nothing answered")
        }
        let option: String
        switch Self.option(for: decision, offered: request["options"] as? [[String: Any]] ?? []) {
        case .success(let id): option = id
        case .failure(let refusal):
            return logger.error("feed bridge: \(item, privacy: .public): \(String(describing: refusal), privacy: .public); nothing answered")
        }
        if decision.outcome == .allow {
            let presence: (context: FeedApproveProofCheck.Context, keys: [String: FeedApproveProofCheck.Key])
            do { presence = try await presenceKeys() } catch {
                return logger.error("feed bridge: \(item, privacy: .public): the presence keys could not be read; nothing answered")
            }
            // The context comes from this Mac's own token: the proof must name this Mac.
            guard own == nil || presence.context.macInstall == own else {
                return logger.error("feed bridge: \(item, privacy: .public): this Mac's install changed; nothing answered")
            }
            if case .failure(let failure) = FeedApproveProofCheck.check(
                decision, by: by, item: item, shownSHA256: entry.shown, context: presence.context,
                keys: presence.keys, now: Date()) {
                return logger.error("feed bridge: \(item, privacy: .public) answered by \(by, privacy: .public) without a valid phone signature (\(String(describing: failure), privacy: .public)); nothing answered")
            }
        }
        let params: [String: Any] = [
            "sessionId": entry.session, "permissionId": entry.permission, "optionId": option,
            "_meta": ["acpmux": ["answeredBy": ["device": by, "feedItem": item]]],
        ]
        if await call("_acpmux/permission_respond", params) == nil {
            logger.error("feed bridge: acpmux refused the answer for \(item, privacy: .public)")
        } else {
            logger.info("feed bridge: answered \(entry.permission, privacy: .public) with \(option, privacy: .public) for \(by, privacy: .public) (\(device, privacy: .public))")
        }
    }

    nonisolated static func cut(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}
