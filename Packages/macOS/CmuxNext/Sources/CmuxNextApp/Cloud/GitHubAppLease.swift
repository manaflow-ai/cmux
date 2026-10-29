import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextHomeEngine
import CmuxNextWakeups
import CryptoKit
import Foundation
import os

/// Lends this app's acpmux daemon the signed-in user's cmux sign-in (a Mac install token minted
/// for the active team, and that team's cmux id, whose GitHub connection Cloud mints from; it
/// checks the user is in it), so that when `gh` on this Mac has no keyring login, the daemon can ask cmux Cloud
/// for a GitHub App token scoped to the one repository of an action it runs for a machine the
/// person added (acpmux `github_app_token.rs`; the person connects GitHub in Settings). The
/// daemon keeps it in memory only and sends it nowhere but the cmux API; sign-out takes it
/// back. It goes over a connection whose daemon was checked first (``AcpmuxPersonLine``), again
/// before it expires, and every few minutes so a restarted daemon has it soon.
///
/// Lends and clears of one account change go one at a time, in order (`tail`), and each carries
/// the `seq` of its account change, which only grows: the daemon refuses an older one, so a lend
/// that arrives after the sign-out that outdated it never restores the sign-in. A later change
/// waits for none of an earlier one's (a token fetch can hang): its newer `seq` already
/// outranks whatever the earlier one still sends, which never retries past it. On a switch of user or team
/// the earlier sign-in is cleared before the new one is fetched, so a failure leaves none.
@MainActor final class GitHubAppLease {
    /// One `_acpmux/github_app_lease` call; the daemon's reply, nil if none.
    typealias Call = @MainActor (_ params: [String: Any]) async -> [String: Any]?
    /// A Mac install token for `team` (a cmux team id).
    typealias Tokens = @MainActor (_ team: String) async throws -> String

    private let origin: String?
    private let call: Call
    private let tokens: Tokens
    private let renewal = DemandTimer(owner: "GitHubAppLease.renewal")
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "github-app-lease")
    /// Moves on with each account change, so a lend for an earlier one never lands.
    private(set) var generation = 0
    /// The current account change's `seq` (ms, and past every earlier one).
    private var seq: UInt64 = 0
    /// Failures in a row of the current account change (read by tests).
    private(set) var failures = 0
    /// The last lend or clear queued; the next waits for it.
    private var tail: Task<Void, Never>?
    /// The account change (`generation`) `tail` is for.
    private var tailGeneration = -1
    /// Every lend and clear not done yet, by when it was queued; each removes itself (``settled()``).
    private var running: [Int: Task<Void, Never>] = [:]
    private var queued = 0

    /// Lend again this long before the token's `exp`.
    nonisolated static let renewMargin: TimeInterval = 90
    /// And at least this often, for a daemon that restarted without it.
    nonisolated static let resend: TimeInterval = 300
    /// Waits after a failure (the daemon may still be starting), the last repeating.
    nonisolated static let retryDelays: [Duration] = [.seconds(5), .seconds(15), .seconds(60), .seconds(300)]

    convenience init(identity: MacInstallIdentity, apiBaseURL: URL, environment: @escaping @MainActor () -> AcpmuxEnvironment?) {
        self.init(origin: HomeCloudLease.origin(apiBaseURL),
                  call: { params in await Self.send(environment(), params) },
                  tokens: { team in
                      // An install token acts only in the team it was minted for: the install's
                      // own for its personal team, else one minted for this team.
                      let own = try await identity.installToken()
                      return Self.claims(ofToken: own).team == team ? own : try await identity.installToken(team: team)
                  })
    }

    init(origin: String?, call: @escaping Call, tokens: @escaping Tokens) {
        self.origin = origin
        self.call = call
        self.tokens = tokens
    }

    /// The cmux team the next lend names (``backendTeam(stackProjectID:userID:stackTeamID:managed:)``).
    private var team: String?

    /// The cmux backend's id of the team a lend names (backend `domains/user.ts`, ids derived so
    /// that routing needs no lookup): the active Stack team's (`stackTeamIdFor`), or with none
    /// the user's personal team (`personalTeamIdFor`). Nil signed out, and when the organization
    /// manages the account and no team is active (cmux is off for it there).
    nonisolated static func backendTeam(stackProjectID: String, userID: String?, stackTeamID: String?, managed: Bool) -> String? {
        guard let userID else { return nil }
        if let stackTeamID { return "team_" + hex20("stack-team:\(stackProjectID):\(stackTeamID)") }
        if managed { return nil }
        let user = CloudIdentity.workerUserID(stackProjectID: stackProjectID, stackUserID: userID)
        return "team_" + hex20("personal:\(user)")
    }

    private nonisolated static func hex20(_ text: String) -> String {
        String(SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(20))
    }

    /// The account the lease last followed. The first one seen always counts, signed out
    /// included, so a daemon that kept a lease from the app's last run has it cleared.
    nonisolated struct Account {
        private var last: (user: String?, team: String?)?

        /// Whether `user` in `team` differs from the last one (and is now the last).
        mutating func changed(user: String?, team: String?) -> Bool {
            if let last, last.user == user, last.team == team { return false }
            last = (user, team)
            return true
        }
    }

    /// The cmux user id (`user_…`) the lent token must be for; nil signed out.
    private var user: String?
    /// The sign-in before this account change is cleared from the daemon (``lendNow`` does it
    /// first).
    private var fenced = false

    /// The signed-in user or the team changed (`user` is the cmux user id, nil signed out;
    /// `team` is ``backendTeam(stackProjectID:userID:stackTeamID:managed:)``). The daemon's
    /// lease is cleared first (again until it says so), so no earlier sign-in or team stays
    /// usable; then, with a user and a team, this one is lent.
    func accountChanged(user: String?, team: String?) {
        self.user = user
        self.team = team
        generation += 1
        seq = max(seq + 1, UInt64(Date().timeIntervalSince1970 * 1000))
        failures = 0
        fenced = false
        renewal.cancel()
        guard user != nil, team != nil else {
            clear(generation)
            return
        }
        lend(generation)
    }

    /// A sign-out started (``CloudService/willSignOut``): the lease is cleared now, not once the
    /// sign-out ends, since its install revoke may fail or take a while and the daemon must not
    /// mint with this sign-in meanwhile.
    func signOutStarted() {
        accountChanged(user: nil, team: nil)
    }

    /// Every lend and clear queued so far has run (for tests).
    func settled() async {
        while let task = running.values.first { await task.value }
    }

    func clear(_ generation: Int) {
        enqueue(generation) { [weak self] in await self?.clearNow(generation) }
    }

    /// One clear; if the daemon did not take it, again after the next retry delay, until it
    /// does or the account changes again.
    private func clearNow(_ generation: Int) async {
        guard generation == self.generation else { return }
        if await take(["seq": seq, "clear": true], generation) {
            if generation == self.generation { failures = 0 }
            return
        }
        guard generation == self.generation else { return }
        let wait = Self.retryDelays[min(failures, Self.retryDelays.count - 1)]
        failures += 1
        renewal.schedule(after: wait) { @MainActor [weak self] in self?.clear(generation) }
    }

    /// Sends `params` (with the current `seq`); whether the daemon took it. One it refused as
    /// older than what it holds (a daemon that outlived an app run whose clock was ahead) moves
    /// `seq` past the daemon's and goes once more.
    private func take(_ params: [String: Any], _ generation: Int) async -> Bool {
        var params = params
        for _ in 0..<2 {
            guard let reply = await call(params) else { return false }
            guard reply["stale"] as? Bool == true else { return true }
            // An earlier account change's call never goes again past a later one's.
            guard generation == self.generation else { return false }
            let held = (reply["seq"] as? NSNumber)?.uint64Value ?? seq
            seq = max(seq, held) + 1
            params["seq"] = seq
        }
        return false
    }

    /// Runs `operation` after every one queued before it. One for an earlier account change (a
    /// renewal or retry timer that fired as the change came) is dropped here: queued, it would
    /// cancel the current change's tail, such as a sign-out's clear.
    private func enqueue(_ generation: Int, _ operation: @escaping @MainActor () async -> Void) {
        guard generation == self.generation else { return }
        let previous = generation == tailGeneration ? tail : nil
        // An earlier account change's calls are superseded: its token fetch is cancelled, so
        // changes in a row never pile up waiting fetches.
        if generation != tailGeneration { tail?.cancel() }
        tailGeneration = generation
        queued += 1
        let id = queued
        // task-owner: one lend or clear, after the one before it; ends with its reply or deadline
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await operation()
            self?.running[id] = nil
        }
        tail = task
        running[id] = task
    }

    func stop() {
        generation += 1
        renewal.cancel()
    }

    func lend(_ generation: Int) {
        enqueue(generation) { [weak self] in await self?.lendNow(generation) }
    }

    private func lendNow(_ generation: Int) async {
        guard generation == self.generation else { return }
        let wait: Duration
        do {
            guard let origin, let team, let user else { throw Failure.noTeam }
            // The sign-in before this change goes first: if what follows fails, none is in use.
            if !fenced {
                guard await take(["seq": seq, "clear": true], generation) else { throw Failure.noDaemon }
                guard generation == self.generation else { return }
                fenced = true
                seq += 1
            }
            let token = try await tokens(team)
            // The install identity follows the account in an observer of its own: a token still
            // of the user (or team) before is never lent for this one.
            let claims = Self.claims(ofToken: token)
            guard claims.user == user, claims.team == team else { throw Failure.otherAccount }
            let expiresAtMs = HomeCloudLease.expiry(ofJWT: token) ?? HomeCloudLease.fallbackExpiry(now: Date())
            guard generation == self.generation else { return }
            let params: [String: Any] = [
                "seq": seq, "origin": origin, "bearer": token, "team": team, "expiresAtMs": expiresAtMs,
            ]
            guard await take(params, generation) else { throw Failure.noDaemon }
            guard generation == self.generation else { return }
            failures = 0
            let remaining = TimeInterval(expiresAtMs) / 1000 - Date().timeIntervalSince1970
            wait = .seconds(max(10, min(Self.resend, remaining - Self.renewMargin)))
        } catch {
            // A superseded change's failure is not the current one's.
            guard generation == self.generation else { return }
            if failures == 0 { logger.info("github app lease: \(String(describing: error), privacy: .public)") }
            wait = Self.retryDelays[min(failures, Self.retryDelays.count - 1)]
            failures += 1
        }
        guard generation == self.generation else { return }
        renewal.schedule(after: wait) { @MainActor [weak self] in self?.lend(generation) }
    }

    /// The `sub` (the cmux user id) and `team` claims of an install token: read to check which
    /// account and team it is for, never trusted as a credential.
    nonisolated static func claims(ofToken token: String) -> (user: String?, team: String?) {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return (nil, nil) }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
        return (claims["sub"] as? String, claims["team"] as? String)
    }

    /// `_acpmux/github_app_lease` on a checked connection; the daemon's reply.
    private static func send(_ environment: AcpmuxEnvironment?, _ params: [String: Any]) async -> [String: Any]? {
        guard let environment, let line = await AcpmuxPersonLine.open(environment) else { return nil }
        return await send(on: line, params)
    }

    /// The call on `line`, only once acpmux took its person proof. `open` also returns a line whose
    /// proof was refused or never asked for (an older daemon, or another one at the socket path),
    /// and the sign-in must never reach that daemon at all, not even to be refused.
    static func send(on line: some AgentDialogLine, _ params: [String: Any]) async -> [String: Any]? {
        defer { line.close() }
        guard line.isPerson else { return nil }
        return await line.call("_acpmux/github_app_lease", params)
    }

    private enum Failure: Error {
        case noTeam
        case noDaemon
        case otherAccount
    }
}
