public import CmuxInstallAuthCore
import CmuxNextWakeups
public import Foundation

/// The signed Cloud capability (cmux-platform#1126; Leo, 2026-11-09: "can't we just pre-approve peopel
/// sometimes? the handshakes themsleves take ms, no?"): minted with this Mac's install token at sign-in, on a
/// team switch, on Cloud intent and before the held one is due, never on a start; sent in
/// ``header`` on every op the credential relay posts to `/v1/ops` and `/v1/read` with a token of the same
/// team, so the Worker skips that call's plan and membership reads. Held in this actor's memory only:
/// never written to disk, the keychain or a log. The rules (what a mint holds, what a call sends, when to
/// mint) are Rust's (cmux-cloud-start-core `capability`, ``Rules/rust``); this keeps the token, the clock
/// and the HTTP. An FFI that does not answer holds and sends nothing: today's full checks.
public actor CloudCapabilityHolder {
    /// The request header (cmux-platform `CAPABILITY_HEADER`).
    public static let header = "x-cmux-cloud-capability"
    /// The mint route, relative to the API origin.
    public static let path = "v1/cloud/capability"

    /// `POST v1/cloud/capability` with `bearer` and no body: the status and the body.
    public typealias Mint = @Sendable (_ bearer: String) async throws -> (status: Int, body: Data)
    /// This Mac's install token, the one the relay sends its ops with.
    public typealias Token = @Sendable () async throws -> String
    /// The team an install token names (``MacInstallIdentity/team(ofToken:)``).
    public typealias TeamOf = @Sendable (_ token: String) -> String?

    /// The capability held, its times on this Mac's clock (ms).
    public struct Held: Codable, Equatable, Sendable {
        public var token: String
        public var team: String
        public var expiresAt: Int64
        public var refreshAt: Int64

        public init(token: String, team: String, expiresAt: Int64, refreshAt: Int64) {
            (self.token, self.team, self.expiresAt, self.refreshAt) = (token, team, expiresAt, refreshAt)
        }
    }

    /// Why the holder asks: a relayed call wants its header, the refresh timer, or sign-in, a team switch or intent.
    public enum Reason: String, Codable, Sendable { case call, timer, intent }

    /// What the holder knows when it asks ``Rules/plan``.
    public struct State: Codable, Equatable, Sendable {
        public var held: Held?
        public var team: String?
        public var now: Int64
        public var failedAt: Int64?
        public var failedTeam: String?
        public var lastUse: Int64?

        public init(held: Held?, team: String?, now: Int64, failedAt: Int64? = nil, failedTeam: String? = nil, lastUse: Int64? = nil) {
            (self.held, self.team, self.now) = (held, team, now)
            (self.failedAt, self.failedTeam, self.lastUse) = (failedAt, failedTeam, lastUse)
        }
    }

    /// The header value a call sends, whether to mint now, and how long until the timer asks again.
    public struct Plan: Codable, Equatable, Sendable {
        public var send: String?
        public var fetch: Bool
        public var wakeIn: Int64?

        public init(send: String?, fetch: Bool, wakeIn: Int64?) {
            (self.send, self.fetch, self.wakeIn) = (send, fetch, wakeIn)
        }
    }

    /// The capability rules: Rust's over the app FFI (``rust``). Nil from either means none held, nothing sent.
    public struct Rules: Sendable {
        /// The held capability from a mint's answer (status, body) for a team, received at `now`.
        public var mint: @Sendable (_ status: Int, _ body: Data, _ team: String, _ now: Int64) -> Held?
        public var plan: @Sendable (_ state: State, _ reason: Reason) -> Plan?

        public init(mint: @escaping @Sendable (Int, Data, String, Int64) -> Held?, plan: @escaping @Sendable (State, Reason) -> Plan?) {
            (self.mint, self.plan) = (mint, plan)
        }

        /// cmux-cloud-start-core `capability` (`cloud_capability_mint`, `cloud_capability_plan`).
        public static let rust = Rules(
            mint: { status, body, team, now in
                struct Reply: Decodable { var held: Held? }
                let parsed = (try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])) ?? NSNull()
                let request: [String: Any] = ["status": status, "body": parsed, "team": team, "now": now]
                guard let data = try? JSONSerialization.data(withJSONObject: request),
                      let reply = CloudStartCore().callData("cloud_capability_mint", data) else { return nil }
                return (try? JSONDecoder().decode(Reply.self, from: reply))?.held
            },
            plan: { state, reason in
                struct Request: Encodable { var state: State, reason: Reason }
                return CloudStartCore().call("cloud_capability_plan", Request(state: state, reason: reason), as: Plan.self)
            })
    }

    private let mint: Mint
    private let token: Token
    private let teamOf: TeamOf
    private let rules: Rules
    private let now: @Sendable () -> Int64

    private var held: Held?
    private var failed: (at: Int64, team: String)?
    private var lastUse: Int64?
    private var minting: Task<Void, Never>?
    /// The team ``minting`` mints for: a mint for another team supersedes it.
    private var mintingTeam: String?
    /// Wakes at the held one's refresh time (one deadline, never a poll).
    private let timer = DemandTimer(owner: "CloudCapabilityHolder.refresh")
    /// Bumped by ``clear()``: a mint in flight for the signed-out account keeps nothing.
    private var generation: UInt64 = 0

    public init(mint: @escaping Mint, token: @escaping Token, teamOf: @escaping TeamOf = MacInstallIdentity.team(ofToken:),
                rules: Rules = .rust, now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.mint = mint
        self.token = token
        self.teamOf = teamOf
        self.rules = rules
        self.now = now
    }

    /// Mints with `transport` (the install transport the relay posts with) and `headers` (its client version).
    public init(transport: any InstallAuthTransport, headers: [String: String], token: @escaping Token,
                teamOf: @escaping TeamOf = MacInstallIdentity.team(ofToken:), rules: Rules = .rust) {
        self.init(mint: { bearer in try await transport.post(Self.path, json: Data("{}".utf8), bearer: bearer, headers: headers) },
                  token: token, teamOf: teamOf, rules: rules)
    }

    /// The credential relay's post (``CloudCredentialRelay/Post``): `path` with `bearer` and `headers`, plus the
    /// capability `capability` holds for `bearer`'s team when there is one. Nothing else changes about the call.
    public nonisolated static func relayPost(transport: any InstallAuthTransport, headers: [String: String],
                                             capability: CloudCapabilityHolder?)
        -> @Sendable (_ path: String, _ body: Data, _ bearer: String) async throws -> (status: Int, body: Data) {
        { path, body, bearer in
            var sent = headers
            if let value = await capability?.header(forBearer: bearer) { sent[Self.header] = value }
            return try await transport.post(path, json: body, bearer: bearer, headers: sent)
        }
    }

    /// The capability a call going with `bearer` sends, or nil. Never waits for a mint: when one is due it
    /// starts in the background and this call goes with what is held (or none, today's full checks).
    public func header(forBearer bearer: String) -> String? {
        let team = teamOf(bearer)
        lastUse = now()
        let plan = ask(.call, team: team)
        if plan?.fetch == true { startMint(bearer: bearer, team: team) }
        return plan?.send
    }

    /// Sign-in, a team switch or the person's Cloud intent: mints now when none is held for the install
    /// token's team or the held one is due. Returns once that mint (if any) has answered.
    public func intent() async {
        lastUse = now()
        let bound = generation
        guard let bearer = try? await token(), bound == generation else { return }
        let team = teamOf(bearer)
        if ask(.intent, team: team)?.fetch == true { startMint(bearer: bearer, team: team) }
        await minting?.value
    }

    /// Sign-out: forgets the capability and stops the timer; a mint in flight keeps nothing.
    public func clear() {
        generation &+= 1
        held = nil
        failed = nil
        lastUse = nil
        minting?.cancel()
        minting = nil
        mintingTeam = nil
        timer.cancel()
    }

    /// Whether a capability is held now (tests and diagnostics; never the token itself).
    public var holds: Bool { held != nil }

    private func ask(_ reason: Reason, team: String?) -> Plan? {
        rules.plan(State(held: held, team: team, now: now(), failedAt: failed?.at, failedTeam: failed?.team, lastUse: lastUse), reason)
    }

    private func startMint(bearer: String, team: String?) {
        guard let team, minting == nil || mintingTeam != team else { return }
        minting?.cancel() // another team's mint: its answer is dropped (minted's team check)
        mintingTeam = team
        let bound = generation
        // task-owner: minting; one mint at a time, cancelled by clear(), ended by the transport's own timeout.
        minting = Task { [mint] in
            let answer = try? await mint(bearer)
            self.minted(answer, team: team, generation: bound)
        }
    }

    private func minted(_ answer: (status: Int, body: Data)?, team: String, generation bound: UInt64) {
        guard bound == generation, team == mintingTeam else { return }
        minting = nil
        mintingTeam = nil
        guard let answer, let next = rules.mint(answer.status, answer.body, team, now()) else {
            failed = (now(), team)
            schedule() // a held one's refresh retries when the backoff ends (Rust's plan), while Cloud is in use
            return
        }
        held = next
        failed = nil
        schedule()
    }

    /// Wakes when the held one is due, and mints again then while Cloud is in use (Rust's `IDLE_STOP_MS`).
    private func schedule() {
        guard let wake = ask(.timer, team: held?.team)?.wakeIn else { timer.cancel(); return }
        let bound = generation
        timer.schedule(after: .milliseconds(max(wake, 1_000))) { [weak self] in await self?.wake(generation: bound) }
    }

    private func wake(generation bound: UInt64) async {
        guard bound == generation else { return }
        guard let bearer = try? await token() else {
            // A failed token is a failed refresh: the same backoff, then the timer tries again.
            guard bound == generation, let team = held?.team else { return }
            failed = (now(), team)
            schedule()
            return
        }
        let team = teamOf(bearer)
        guard bound == generation, ask(.timer, team: team)?.fetch == true else { return }
        startMint(bearer: bearer, team: team)
    }
}
