import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextHostedChief
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
    /// One POST to the API Worker as the signed-in user (Pair Another Machine mints its invite with it).
    let call: Call
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
    static func app(feed: FeedService, auth: CloudAuth, cli: BundledExecutable, chiefPlaced: @escaping @MainActor () -> Void = {}) -> CloudPairingSource {
        CloudPairingSource(
            inner: LocalServerSource.app(cli: cli),
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
        case let .revokeDevice(host):
            run(intent.key) { [weak self] in await self?.revoke(host: host, key: intent.key) }
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
            return emit(.candidate(nil), .settled(key: key, reject: Self.signedOut))
        }
        do {
            let team = try await workerTeam(account: account)
            let reply = try await call("v1/read", ["op": "server.pair.preview", "params": ["code": code]])
            guard let candidate = PairingCandidate(preview: try Self.okValue(reply), team: team) else {
                return emit(.candidate(nil), .settled(key: key, reject: Self.text("refusal.server.pairKeyUnchecked", "The server's key could not be checked. Ask the server for a new code.")))
            }
            emit(.candidate(candidate), .settled(key: key, reject: nil))
        } catch let FeedServiceError.owner(code: errorCode, message: message) where errorCode != "selector.not_found" {
            emit(.candidate(nil), .settled(key: key, reject: Self.format("refusal.server.pairFailed", "Could not add the server: %@", message)))
        } catch FeedServiceError.owner {
            emit(.candidate(nil), .settled(key: key, reject: Self.text("refusal.server.pairNotFound", "No server is waiting with that code.")))
        } catch {
            emit(.candidate(nil), .settled(key: key, reject: Self.reject(for: error)))
        }
    }

    /// The Worker's team for this session, or nil when signed out ("Pair Another Machine…" mints its
    /// invite into it, as Add Server approves into it).
    func workerTeam() async throws -> ServerTeam? {
        guard let account = account() else { return nil }
        return try await workerTeam(account: account)
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
        guard account() != nil else { return emit(.settled(key: key, reject: Self.signedOut)) }
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
                    return emit(.settled(key: key, reject: reject))
                }
            }
            emit(.settled(key: key, reject: nil))
        } catch let FeedServiceError.owner(_, message) {
            emit(.settled(key: key, reject: Self.format("refusal.server.pairFailed", "Could not add the server: %@", message)))
        } catch {
            emit(.settled(key: key, reject: Self.reject(for: error)))
        }
    }

    /// `server.revoke {host}` as the signed-in user (origin user, the intent's key as idempotency key).
    private func revoke(host: String, key: String) async {
        let body: [String: Any] = ["op": "server.revoke", "params": ["host": host], "idempotency_key": key, "origin": "user"]
        do {
            _ = try Self.okValue(try await call("v1/ops", body))
            emit(.settled(key: key, reject: nil))
        } catch let FeedServiceError.owner(_, message) {
            emit(.settled(key: key, reject: Self.format("refusal.server.revokeFailed", "Could not revoke access: %@", message)))
        } catch {
            emit(.settled(key: key, reject: Self.reject(for: error)))
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
            emit(.chief(status ?? nil))
        }
    }

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

    /// A request stop() cancelled is the stopped session's: it never reaches a later start()'s sink.
    private func emit(_ events: ServerSourceEvent...) {
        guard !Task.isCancelled else { return }
        for event in events { sink?(event) }
    }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        RefusalStrings.text(key, value)
    }

    private static func format(_ key: StaticString, _ value: String.LocalizationValue, _ argument: String) -> String {
        RefusalStrings.format(key, value, argument)
    }
}
