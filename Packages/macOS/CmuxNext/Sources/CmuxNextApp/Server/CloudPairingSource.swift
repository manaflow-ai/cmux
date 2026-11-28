import CmuxNextCloud
import CmuxNextServer
import Foundation

/// "Add Server…" on a signed-in Mac (plans/cmux-next/server.md 6.2 steps 3-4):
/// looks a code up with `server.pair.preview` and approves it with
/// `server.pair.approve` (origin user, the intent's key as the idempotency
/// key) through the API Worker. Every other intent goes to `inner`, which
/// serves this Mac's own `server.status` (`LocalServerSource`).
@MainActor
final class CloudPairingSource: ServerSource {
    /// One POST to the API Worker as the signed-in user (`v1/read`, `v1/ops`).
    typealias Call = @MainActor (_ path: String, _ body: [String: Any]) async throws -> [String: Any]

    private let inner: any ServerSource
    private let call: Call
    /// The approver's name for the team chip, or nil when signed out.
    private let account: @MainActor () -> String?
    /// The user's Chief moved to a server (Home re-checks its Chief tab).
    private let chiefPlaced: @MainActor () -> Void
    private var sink: (@MainActor (ServerSourceEvent) -> Void)?
    private var work: [String: Task<Void, Never>] = [:]

    /// The App's source: this Mac's status from the bundled CLI plus cloud pairing
    /// as the signed-in user. Phase 1 pairs into the Worker's team for the
    /// session (the personal team, server.md 6.2 step 4), read from the
    /// Worker: the app's Stack team id is not a Worker team id.
    static func app(feed: FeedService, auth: CloudAuth, chiefPlaced: @escaping @MainActor () -> Void = {}) -> CloudPairingSource {
        CloudPairingSource(
            inner: LocalServerSource.app(),
            call: { [weak feed] path, body in
                guard let feed else { throw FeedServiceError.signedOut }
                return try await feed.call(path, body)
            },
            account: { [weak auth] in
                guard let auth, auth.isSignedIn else { return nil }
                return auth.user?.displayName ?? auth.user?.primaryEmail ?? ""
            },
            chiefPlaced: chiefPlaced
        )
    }

    init(inner: any ServerSource, call: @escaping Call, account: @escaping @MainActor () -> String?,
         chiefPlaced: @escaping @MainActor () -> Void = {}) {
        self.inner = inner
        self.call = call
        self.account = account
        self.chiefPlaced = chiefPlaced
    }

    func start(_ sink: @escaping @MainActor (ServerSourceEvent) -> Void) {
        self.sink = sink
        inner.start(sink)
        refreshChief()
    }

    func send(_ intent: ServerIntent) {
        switch intent.kind {
        case let .lookupCode(code):
            run(intent.key) { [weak self] in await self?.lookup(PairingCode.normalize(code), key: intent.key) }
        case let .approveCode(code, team, name, placeChief):
            run(intent.key) { [weak self] in
                await self?.approve(code: PairingCode.normalize(code), team: team, name: name, placeChief: placeChief, key: intent.key)
            }
        default:
            inner.send(intent)
        }
    }

    func stop() {
        for task in work.values { task.cancel() }
        work = [:]
        sink = nil
        inner.stop()
    }

    private func run(_ key: String, _ body: @escaping @MainActor () async -> Void) {
        // task-owner: CloudPairingSource, one request per intent; cancelled by stop().
        work[key] = Task { @MainActor [weak self] in
            await body()
            self?.work[key] = nil
        }
    }

    private func lookup(_ code: String, key: String) async {
        guard let account = account() else {
            return settle(key, candidate: nil, reject: Self.signedOut)
        }
        do {
            let team = try await workerTeam(account: account)
            let reply = try await call("v1/read", ["op": "server.pair.preview", "params": ["code": code]])
            guard let candidate = Self.candidate(from: try Self.okValue(reply), team: team) else {
                return settle(key, candidate: nil, reject: Self.text("refusal.server.pairKeyUnchecked", "The server's key could not be checked. Ask the server for a new code."))
            }
            settle(key, candidate: candidate, reject: nil)
        } catch let FeedServiceError.owner(code: errorCode, message: message) where errorCode != "selector.not_found" {
            settle(key, candidate: nil, reject: Self.format("refusal.server.pairFailed", "Could not add the server: %@", message))
        } catch FeedServiceError.owner {
            settle(key, candidate: nil, reject: Self.text("refusal.server.pairNotFound", "No server is waiting with that code."))
        } catch {
            settle(key, candidate: nil, reject: Self.reject(for: error))
        }
    }

    /// The Worker's team for this session, from `team.policy.get`. A user
    /// who only ever signed in on a Mac has no personal team yet: on
    /// `auth.forbidden` run `user.ensure` (idempotent) once and read again.
    private func workerTeam(account: String) async throws -> ServerTeam {
        let read: [String: Any] = ["op": "team.policy.get", "params": [String: Any]()]
        let reply: [String: Any]
        do {
            reply = try await call("v1/read", read)
            _ = try Self.okValue(reply)
        } catch FeedServiceError.owner(code: "auth.forbidden", message: _) {
            let ensure: [String: Any] = [
                "op": "user.ensure", "params": [String: Any](),
                "idempotency_key": "server-pair-ensure-\(UUID().uuidString)", "origin": "user",
            ]
            _ = try await call("v1/ops", ensure)
            return try await teamFromRead(try await call("v1/read", read), account: account)
        }
        return try teamFromRead(reply, account: account)
    }

    private func teamFromRead(_ reply: [String: Any], account: String) throws -> ServerTeam {
        guard let value = try Self.okValue(reply) as? [String: Any], let id = value["team"] as? String, !id.isEmpty else {
            throw FeedServiceError.badReply
        }
        return ServerTeam(id: id, name: account.isEmpty ? id : account)
    }

    private func approve(code: String, team: String, name: String, placeChief: Bool, key: String) async {
        guard account() != nil else { return sink?(.settled(key: key, reject: Self.signedOut)) ?? () }
        let body: [String: Any] = [
            "op": "server.pair.approve",
            "params": ["code": code, "team": team, "name": name],
            "idempotency_key": key,
            "origin": "user",
        ]
        do {
            let reply = try await call("v1/ops", body)
            // Success only with the enrolled host: a Worker error reply
            // (`{_tag, code, message}`) has no `value.host`.
            let value = try Self.okValue(reply) as? [String: Any]
            guard let host = value?["host"] as? String else { throw FeedServiceError.badReply }
            if placeChief {
                // The server is added either way; a Chief that could not move says so.
                if let reject = await self.placeChief(host: host, install: value?["install"] as? String, key: key) {
                    return sink?(.settled(key: key, reject: reject)) ?? ()
                }
            }
            sink?(.settled(key: key, reject: nil))
        } catch let FeedServiceError.owner(_, message) {
            sink?(.settled(key: key, reject: Self.format("refusal.server.pairFailed", "Could not add the server: %@", message)))
        } catch {
            sink?(.settled(key: key, reject: Self.reject(for: error)))
        }
    }

    /// Places the user's Chief on the server just approved (G8); a refusal
    /// text, or nil when the Chief now runs there.
    private func placeChief(host: String, install: String?, key: String) async -> String? {
        defer { refreshChief() }
        guard let install else { return Self.chiefNotMoved("the server has no install") }
        do {
            _ = try await CloudChiefs.place(CloudChief.BrainPlace(host: host, install: install), key: key, call: call)
            chiefPlaced()
            return nil
        } catch let FeedServiceError.owner(_, message) {
            return Self.chiefNotMoved(message)
        } catch {
            return Self.chiefNotMoved(Self.reject(for: error))
        }
    }

    /// Reads where the user's Chief runs for the panel (once per open, after an approve).
    private func refreshChief() {
        guard account() != nil else { return }
        run("chief-status") { [weak self] in
            guard let self else { return }
            let status = try? await CloudChiefStatus.read(call: call)
            guard !Task.isCancelled else { return }
            sink?(.chief(status ?? nil))
        }
    }

    /// The pairing capability of a server that runs a user's Chief (`optchat-chief cloud pair`).
    nonisolated static let chiefBrainCapability = "optchat-chief-brain"

    private static func chiefNotMoved(_ reason: String) -> String {
        format("refusal.server.chiefNotMoved", "The server was added, but your Chief could not move to it: %@", reason)
    }

    /// The `value` of a successful reply; a Worker error reply
    /// (`{_tag, code, message}`) is thrown as an owner error.
    nonisolated static func okValue(_ reply: [String: Any]) throws -> Any? {
        if reply["_tag"] != nil, let code = reply["code"] as? String {
            throw FeedServiceError.owner(code: code, message: reply["message"] as? String ?? code)
        }
        return reply["value"]
    }

    private static var signedOut: String { text("refusal.server.pairSignedOut", "Sign in to cmux to add a server.") }

    /// Fixed text for errors that are not the owner's (no raw error dumps).
    private static func reject(for error: any Error) -> String {
        if case FeedServiceError.signedOut = error { return signedOut }
        return text("refusal.server.pairUnreachable", "Could not reach cmux. Check the connection and try again.")
    }

    private func settle(_ key: String, candidate: PairingCandidate?, reject: String?) {
        sink?(.candidate(candidate))
        sink?(.settled(key: key, reject: reject))
    }

    /// The approver's facts from a `PairingPreview`; nil when the thumbprint
    /// gives no fingerprint words (the words are the user's swap check).
    nonisolated static func candidate(from value: Any?, team: ServerTeam) -> PairingCandidate? {
        guard let value = value as? [String: Any],
              let code = value["code"] as? String,
              let info = value["info"] as? [String: Any],
              let thumbprint = value["thumbprint"] as? String,
              let words = PairingWords.words(thumbprint: thumbprint) else { return nil }
        let platform = info["platform"] as? String ?? ""
        let osVersion = info["os_version"] as? String ?? ""
        return PairingCandidate(
            code: code,
            name: info["name"] as? String ?? code,
            os: [platform, osVersion].filter { !$0.isEmpty }.joined(separator: " "),
            version: info["cmux_version"] as? String ?? "",
            region: value["country"] as? String,
            words: words,
            teams: [team],
            // `optchat-chief cloud pair` declares the capability; the paired install keeps it.
            isChiefBrain: (info["capabilities"] as? [String])?.contains(Self.chiefBrainCapability) == true
        )
    }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        RefusalStrings.text(key, value)
    }

    private static func format(_ key: StaticString, _ value: String.LocalizationValue, _ argument: String) -> String {
        RefusalStrings.format(key, value, argument)
    }
}
