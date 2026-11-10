public import CmuxInstallAuthCore
import CmuxNextCompat
import CmuxNextWakeups
import CryptoKit
public import Foundation
import os

/// The Mac app's Cloud install principal (bead cx-wb5.64; identity spec D5):
/// an install key and a record per Stack user, registered as kind `mac` with
/// the mac grant (read, mutate-own, mutate-shared, cloud-link; never execute;
/// the server caps it) when the user signs in, then short-lived install
/// tokens minted from the key without the Stack session. Sign-out revokes the
/// install and forgets its key and record, so the next sign-in registers a
/// new install. The credential relay (cx-wb5.63) sends Cloud ops with these
/// tokens; a Stack bearer never leaves the app.
///
/// Every bind has a generation: a registration that is still in flight when
/// the user signs out (or another user signs in) never writes its record, so
/// nothing on disk can mint for it afterwards. Its install may stay on the
/// server, unusable (its key is rotated away).
public actor MacInstallIdentity {
    public enum Failure: Error, Equatable {
        /// No user is signed in.
        case signedOut
    }

    private let store: MacInstallStore
    private let transport: any InstallAuthTransport
    private let deviceName: String
    private let clientVersion: String?
    private var client: InstallAuthClient?
    private var user: String?
    private var generation: UInt64 = 0
    /// Set by ``signOut(stackUser:session:)`` until the session ends
    /// (``unbind()``): a late sign-in callback registers nothing.
    private var signingOut = false
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.install")
    /// The signed Cloud capability minted with this install's tokens (cmux-platform#1126), in memory only: minted at
    /// each ``signedIn(stackUser:session:)`` (sign-in and every team switch) and on Cloud intent, cleared when the
    /// session ends, and sent by the credential relay on every op it posts.
    public nonisolated let capability: CloudCapabilityHolder

    public init(store: MacInstallStore, transport: any InstallAuthTransport, deviceName: String, clientVersion: String?) {
        self.store = store
        self.transport = transport
        self.deviceName = deviceName
        self.clientVersion = clientVersion
        let source = WeakIdentity()
        capability = CloudCapabilityHolder(transport: transport, headers: InstallAuthClient.headers(clientVersion: clientVersion),
                                           token: {
                                               guard let identity = source.identity else { throw Failure.signedOut }
                                               return try await identity.installToken()
                                           })
        source.identity = self
    }

    /// The identity the capability mints with, held weakly (the identity owns the capability).
    private final class WeakIdentity: Sendable {
        private let state = Mutex<Weak>(Weak())
        private struct Weak { weak var value: MacInstallIdentity? }
        var identity: MacInstallIdentity? {
            get { state.withLock { $0.value } }
            set { state.withLock { $0.value = newValue } }
        }
    }

    /// The user signed in: binds them and registers (or reuses) the install
    /// at once by minting one token, so a later relay call does not wait.
    /// Then the signed Cloud capability for the token's team, beside the first list (not awaited).
    public func signedIn(stackUser: String, session: @escaping InstallAuthClient.SessionToken) async throws {
        guard !signingOut else { throw Failure.signedOut }
        if user != stackUser || client == nil { bind(stackUser: stackUser, session: session) }
        _ = try await installToken()
        let capability = capability
        // task-owner: none; one mint at most, ended by its transport's timeout; unbind() and signOut() clear its answer.
        Task { await capability.intent() }
    }

    /// The headers every install-token request carries (the client
    /// version, so the owner can refuse a too-old app).
    public nonisolated var requestHeaders: [String: String] { InstallAuthClient.headers(clientVersion: clientVersion) }

    /// The `team` claim of an install token (the owner's own token over
    /// TLS; read for consistency, never trusted as a credential). Nil when
    /// the token is not a JWT with a team (Rust's `identity::claims`).
    public nonisolated static func team(ofToken token: String) -> String? {
        struct Claims: Decodable { var team: String? }
        return CloudStartCore().call("cloud_identity_token", ["token": token], as: Claims.self)?.team
    }

    /// A valid install token for the signed-in user.
    public func installToken() async throws -> String {
        guard let client else { throw Failure.signedOut }
        return try await client.installToken()
    }

    /// A fresh token for one backend team, using this install's existing signer and grant.
    /// The personal client stays bound to its own scope; team refusals never rotate its key.
    public func installToken(team: String) async throws -> String {
        guard let client, let stackUser = user else { throw Failure.signedOut }
        let bound = generation
        _ = try await client.installToken()
        guard bound == generation, user == stackUser,
              let record = await client.currentRecord, let environment = await client.environment else { throw Failure.signedOut }
        let scoped = InstallAuthClient(
            transport: transport, signer: store.signer(for: stackUser), sessionToken: nil, stackUser: stackUser,
            deviceName: deviceName, clientVersion: clientVersion, record: record,
            profile: .mac, team: team, expectedEnvironment: environment)
        // In this task, so a caller that is cancelled (a superseded lend) stops the mint too.
        let token = try await scoped.installTokenInCallerTask()
        guard bound == generation, user == stackUser, await client.currentRecord == record else { throw Failure.signedOut }
        return token
    }

    /// The owner refused the current token (401): the next call mints again.
    public func invalidate() async { await client?.invalidate() }

    /// The registered install's id (`inst_…`), or nil before the first
    /// registration of the signed-in user. `cmux link` runs as this install.
    public func installID() async -> String? { await client?.currentRecord?.install }

    /// The signed-in Stack user, the registered install and the API's `ENVIRONMENT`, for a hand proof
    /// (docs/chief-hands.md): mints a token first, which registers the install and learns the
    /// environment from the server's challenge.
    func proofContext() async throws -> (user: String, install: String, environment: String) {
        _ = try await installToken()
        guard let client, let user, let record = await client.currentRecord,
              let environment = await client.environment else { throw Failure.signedOut }
        return (user, record.install, environment)
    }

    /// ES256 by the signed-in user's install key over `message`: raw `r || s`, base64url.
    func signWithInstallKey(_ message: String) async throws -> String {
        guard let user else { throw Failure.signedOut }
        return try await store.signer(for: user).sign(Data(message.utf8)).base64URLEncoded
    }

    /// The session ended without a sign-out here (expired, or signed out
    /// elsewhere): stop minting. The key and record stay, so a sign-in of the
    /// same user reuses the install and a later sign-out can still revoke it.
    public func unbind() async {
        signingOut = false
        await drop()
    }

    /// Stops the bound client: no record write, no token from a mint in flight.
    private func drop() async {
        await capability.clear()
        generation &+= 1
        let dropped = client
        client = nil
        user = nil
        await dropped?.reset()
    }

    /// Sign-out of `stackUser` (needs the Stack session still): revokes the
    /// install on the server, also one stored by an earlier launch that this
    /// one never bound, then always rotates the user's key and forgets the
    /// record, so this Mac never mints for that install again, also when the
    /// revoke failed or a registration was still in flight. Until the session
    /// ends (``unbind()``) no sign-in registers.
    public func signOut(stackUser signedOutUser: String, session: @escaping InstallAuthClient.SessionToken) async {
        signingOut = true
        await drop()
        let client = InstallAuthClient(
            transport: transport, signer: store.signer(for: signedOutUser), sessionToken: session, stackUser: signedOutUser,
            deviceName: deviceName, clientVersion: clientVersion, record: store.record(for: signedOutUser), profile: .mac
        )
        do {
            try await client.revoke()
        } catch {
            logger.error("install revoke failed: \(String(describing: error), privacy: .public)")
        }
        await client.reset()
        store.saveRecord(nil, for: signedOutUser)
        do {
            try await store.signer(for: signedOutUser).rotate()
        } catch {
            logger.error("install key rotation failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func bind(stackUser: String, session: InstallAuthClient.SessionToken?) {
        generation &+= 1
        let bound = generation
        user = stackUser
        client = InstallAuthClient(
            transport: transport, signer: store.signer(for: stackUser), sessionToken: session, stackUser: stackUser,
            deviceName: deviceName, clientVersion: clientVersion, record: store.record(for: stackUser),
            profile: .mac, onRecord: { [weak self] record in await self?.recordChanged(record, for: stackUser, generation: bound) }
        )
    }

    private func recordChanged(_ record: InstallRecord?, for stackUser: String, generation bound: UInt64) {
        guard bound == generation else { return }
        store.saveRecord(record, for: stackUser)
    }
}

/// The signed Cloud capability (cmux-platform#1126; Leo, 2026-11-09: "can't we just pre-approve peopel
/// sometimes? the handshakes themsleves take ms, no?"): minted with this Mac's install token at sign-in, on a
/// team switch, on Cloud intent and before the held one is due, never on a start; sent in ``header`` on every
/// op the credential relay posts to `/v1/ops` and `/v1/read` with a token of the same team, so the Worker skips
/// that call's plan and membership reads. Held in memory only: never written to disk, the keychain or a log.
/// The holder is Rust's (cmux-cloud-start-core `capability::holder`, op `cloud_capability_step`): what it
/// holds, when it mints, a team switch, sign-out and retry. This keeps the install token, the clock, the HTTP
/// and the timer, and runs the effects Rust names. An FFI that does not answer holds and sends nothing.
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

    private let mint: Mint
    private let token: Token
    private let teamOf: TeamOf
    private let now: @Sendable () -> Int64
    /// Rust's state between steps (opaque here), and what its last answer said.
    private var state: String?
    private var generation: UInt64 = 0
    /// Whether a capability is held now (tests and diagnostics; never the token itself).
    public private(set) var holds = false
    private var minting: Task<Void, Never>?
    /// Wakes at the held one's refresh time (one deadline, never a poll).
    private let timer = DemandTimer(owner: "CloudCapabilityHolder.refresh")

    public init(mint: @escaping Mint, token: @escaping Token, teamOf: @escaping TeamOf = MacInstallIdentity.team(ofToken:),
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        (self.mint, self.token, self.teamOf, self.now) = (mint, token, teamOf, now)
    }

    /// Mints with `transport` (the install transport the relay posts with) and `headers` (its client version).
    public init(transport: any InstallAuthTransport, headers: [String: String], token: @escaping Token,
                teamOf: @escaping TeamOf = MacInstallIdentity.team(ofToken:)) {
        self.init(mint: { bearer in try await transport.post(Self.path, json: Data("{}".utf8), bearer: bearer, headers: headers) },
                  token: token, teamOf: teamOf)
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

    /// The capability a call going with `bearer` sends, or nil. Never waits for a mint: one Rust finds due
    /// starts in the background and this call goes with what is held (or none, today's full checks).
    public func header(forBearer bearer: String) -> String? {
        step(Event(on: "call", team: teamOf(bearer)), bearer: bearer)
    }

    /// Sign-in, a team switch or the person's Cloud intent: mints now when Rust finds none held for the install
    /// token's team or the held one due. Returns once that mint (if any) has answered.
    public func intent() async {
        step(Event(on: "use"), bearer: nil)
        let bound = generation
        guard let bearer = try? await token(), bound == generation else { return }
        step(Event(on: "intent", team: teamOf(bearer), generation: bound), bearer: bearer)
        await minting?.value
    }

    /// Sign-out: Rust forgets the capability and stops the timer; a mint in flight keeps nothing.
    public func clear() {
        step(Event(on: "clear"), bearer: nil)
    }

    // MARK: The FFI's words (cmux-cloud-start-core `capability::holder`)

    private struct Event: Encodable {
        var on: String
        var team: String?
        var generation: UInt64?
        var status: Int?
        var body: String?
    }

    private struct Effect: Decodable {
        enum CodingKeys: String, CodingKey { case kind = "do", team, generation, afterMs }
        var kind: String
        var team: String?
        var generation: UInt64?
        var afterMs: Int64?
    }

    private struct Reply: Decodable {
        var state: String
        var send: String?
        var effects: [Effect]
        var holds: Bool
        var generation: UInt64
        var minting: Bool
    }

    /// One event to Rust; runs the effects it names (a mint with `bearer`, the timer) and returns what a call sends.
    @discardableResult
    private func step(_ event: Event, bearer: String?) -> String? {
        struct Request: Encodable { var state: String?, event: Event, now: Int64 }
        guard let reply = CloudStartCore().call("cloud_capability_step", Request(state: state, event: event, now: now()), as: Reply.self)
        else { return nil }
        (state, generation, holds) = (reply.state, reply.generation, reply.holds)
        for effect in reply.effects {
            switch effect.kind {
            case "mint":
                if let bearer, let team = effect.team, let bound = effect.generation { startMint(bearer: bearer, team: team, generation: bound) }
            case "schedule":
                guard let after = effect.afterMs, let bound = effect.generation else { continue }
                timer.schedule(after: .milliseconds(after)) { [weak self] in await self?.wake(generation: bound) }
            case "cancelTimer":
                timer.cancel()
            case "cancelMint":
                minting?.cancel()
                minting = nil
            default:
                continue
            }
        }
        if !reply.minting { minting = nil }
        return reply.send
    }

    private func startMint(bearer: String, team: String, generation bound: UInt64) {
        // task-owner: minting; one mint at a time (Rust's), cancelled by clear(), ended by the transport's own timeout.
        minting = Task { [mint] in
            let answer = try? await mint(bearer)
            self.minted(answer, team: team, generation: bound)
        }
    }

    private func minted(_ answer: (status: Int, body: Data)?, team: String, generation bound: UInt64) {
        let body = answer.map { String(decoding: $0.body, as: UTF8.self) }
        step(Event(on: "minted", team: team, generation: bound, status: answer?.status, body: body), bearer: nil)
    }

    private func wake(generation bound: UInt64) async {
        guard bound == generation, let bearer = try? await token(), bound == generation else { return }
        step(Event(on: "wake", team: teamOf(bearer), generation: bound), bearer: bearer)
    }
}
