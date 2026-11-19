public import CmuxInstallAuthCore
import CmuxNextCompat
public import CmuxNextDaemon
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
        /// Three rounds of the lease neither answered nor named a stall (a token that lapsed as it arrived).
        case mintUnsettled
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
    /// Callers of ``installToken(awaitingBind:)`` waiting for the first bind (or a drop) of this launch.
    private var bindWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.install")
    private let now: @Sendable () -> Date
    /// The clock a mint waiter's deadline runs on (a test's manual clock moves it instead of waiting).
    private let clock: any Clock<Duration>
    /// The lease Rust's `signin::lease` decides on: the token held, the one mint in flight, the last failed mint.
    private var held: Held?
    private var mint: RunningMint?
    private var failedMint: (id: UUID, error: any Error)?
    /// Callers of ``installToken()`` waiting on the running mint, each until its answer or Rust's bound.
    private var mintWaiters: [UUID: MintWaiter] = [:]

    public init(store: MacInstallStore, transport: any InstallAuthTransport, deviceName: String, clientVersion: String?,
                now: @escaping @Sendable () -> Date = Date.init,
                clock: any Clock<Duration> = ContinuousClock()) {
        self.now = now
        self.clock = clock
        self.store = store
        self.transport = transport
        self.deviceName = deviceName
        self.clientVersion = clientVersion
    }

    /// The user signed in: binds them and registers (or reuses) the install
    /// at once by minting one token, so a later relay call does not wait.
    public func signedIn(stackUser: String, session: @escaping InstallAuthClient.SessionToken) async throws {
        guard !signingOut else { throw Failure.signedOut }
        if user != stackUser || client == nil { bind(stackUser: stackUser, session: session) }
        _ = try await installToken()
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

    /// A valid install token for the signed-in user. Rust's lease (cmux-cloud-config `signin`, op
    /// `cloud_auth_install_token_lease`) decides: the held token answers and is renewed beside it at 2/3 of its
    /// life, so a stalled renewal never holds a Cloud call; with no usable token a caller waits on one mint at
    /// most its bound, then gets ``MintStalled`` naming the step, never "the cmux API did not answer".
    public func installToken() async throws -> String {
        guard let client else { throw Failure.signedOut }
        // Each round answers or waits on one mint at most Rust's bound, so the second round has a token, the mint's
        // error or the stall refusal; the third covers a token that lapsed in between.
        for _ in 0..<3 {
            guard let decision = leaseDecision() else { return try await client.installToken() }
            if decision.cancelMint {
                mint?.task.cancel()
                mint = nil
            }
            if decision.startMint { startMint(client) }
            if decision.useHeld, let held { return held.value }
            if let refusal = decision.refusal {
                logger.error("install token: \(refusal["message"]?.stringValue ?? "mint stalled", privacy: .public)")
                throw MintStalled(refusal: refusal)
            }
            guard let until = decision.waitUntilMs, let running = mint else { throw Failure.signedOut }
            await waitForMint(until: Date(timeIntervalSince1970: Double(until) / 1000))
            guard self.client === client else { throw Failure.signedOut }
            // The mint this caller waited on failed: its own error, at once.
            if let failed = failedMint, failed.id == running.id { throw failed.error }
        }
        throw Failure.mintUnsettled
    }

    /// A caller waited the whole bound on a mint (Rust's `signin::lease`): ``refusal`` is Rust's answer
    /// `{code: "credential.minting", message, retryable, details: {mint: {step, waited_seconds, bound_seconds}}}`;
    /// the credential relay sends it as is.
    public struct MintStalled: Error, Sendable, Equatable, CredentialRelayRefusal, CustomStringConvertible {
        public let refusal: JSONValue
        public var relayRefusal: JSONValue { refusal }
        public var description: String { refusal["message"]?.stringValue ?? "the install token mint stalled" }
    }

    private struct Held { var value: String; var mintedAt: Date; var expiresAt: Date }
    private struct RunningMint { var id: UUID; var task: Task<String, Error>; var startedAt: Date; var step: MintStep }

    /// The step a running mint is in; written from the mint's task, read by callers.
    private final class MintStep: Sendable {
        private let state = Mutex("starting the mint")
        var name: String { state.withLock { $0 } }
        func set(_ name: String) { state.withLock { $0 = name } }
    }

    private struct LeaseDecision: Decodable {
        var useHeld: Bool
        var startMint: Bool
        var cancelMint: Bool
        var waitUntilMs: UInt64?
        var refusal: JSONValue?
    }

    private func leaseDecision() -> LeaseDecision? {
        struct HeldFacts: Encodable { var mintedMs: UInt64; var expiresMs: UInt64 }
        struct MintFacts: Encodable { var startedMs: UInt64; var step: String }
        struct Facts: Encodable { var nowMs: UInt64; var held: HeldFacts?; var mint: MintFacts? }
        func ms(_ date: Date) -> UInt64 { UInt64(max(0, date.timeIntervalSince1970 * 1000)) }
        let facts = Facts(nowMs: ms(now()),
                          held: held.map { HeldFacts(mintedMs: ms($0.mintedAt), expiresMs: ms($0.expiresAt)) },
                          mint: mint.map { MintFacts(startedMs: ms($0.startedAt), step: $0.step.name) })
        return CloudStartCore().call("cloud_auth_install_token_lease", facts, as: LeaseDecision.self)
    }

    private func startMint(_ client: InstallAuthClient) {
        let id = UUID(), step = MintStep()
        // task-owner: one mint of this lease; it ends with its answer, a cancel by a stalled lease, or drop().
        let task = Task { [weak self] in
            do {
                let minted = try await client.mintFresh(step: { step.set($0) })
                await self?.minted(id, minted)
                return minted.value
            } catch {
                await self?.mintFailed(id, error)
                throw error
            }
        }
        mint = RunningMint(id: id, task: task, startedAt: now(), step: step)
    }

    private func minted(_ id: UUID, _ token: (value: String, expiresAt: Date)) {
        guard mint?.id == id else { return }
        held = Held(value: token.value, mintedAt: now(), expiresAt: token.expiresAt)
        mint = nil
        wakeMintWaiters()
    }

    private func mintFailed(_ id: UUID, _ error: any Error) {
        guard mint?.id == id else { return }
        failedMint = (id, error)
        mint = nil
        wakeMintWaiters()
    }

    /// Waits until the running mint answers or `until`, whichever is first. A stalled mint's task is never
    /// awaited (awaiting a task ignores the waiter's cancel), so the bound holds.
    private func waitForMint(until: Date) async {
        let remaining = max(0, until.timeIntervalSince(now()))
        let id = UUID()
        let deadline = DemandTimer(owner: "cloud.install.mint-wait", clock: clock)
        await withCheckedContinuation { continuation in
            mintWaiters[id] = MintWaiter(continuation: continuation, deadline: deadline)
            // The one deadline of this wait (Rust's mint bound); the mint's answer or a drop resumes it earlier.
            deadline.schedule(after: .seconds(remaining)) { [weak self] in await self?.wakeMintWaiter(id) }
        }
    }

    private func wakeMintWaiter(_ id: UUID) { mintWaiters.removeValue(forKey: id)?.resume() }

    private func wakeMintWaiters() {
        let waiters = mintWaiters
        mintWaiters = [:]
        for waiter in waiters.values { waiter.resume() }
    }

    /// A caller waiting on the running mint, and the deadline that resumes it at Rust's bound.
    private struct MintWaiter {
        var continuation: CheckedContinuation<Void, Never>
        var deadline: DemandTimer

        func resume() {
            deadline.cancel()
            continuation.resume()
        }
    }

    /// Forgets the lease: the held token and the mint in flight (a 401, a sign-out, another user).
    private func forgetLease() {
        mint?.task.cancel()
        mint = nil
        held = nil
        failedMint = nil
        wakeMintWaiters()
    }

    /// ``installToken()`` for a caller that knows the app is signed in: when the user is not bound yet (the first
    /// Cloud call of a launch can come before the restored session reaches ``signedIn(stackUser:session:)``; Leo's
    /// NIGHTLY logged `install token mint failed: signedOut` on a relaunch), it waits up to `wait` for the bind
    /// instead of answering signed out.
    public func installToken(awaitingBind wait: Duration) async throws -> String {
        if client == nil, !signingOut {
            let id = UUID()
            await withCheckedContinuation { continuation in
                bindWaiters[id] = continuation
                // task-owner: one bounded wait per waiter; the bind, a drop or this deadline resumes it once.
                Task { [weak self] in
                    // wakeup-allow: the one deadline of this wait; it ends earlier when a bind wakes the waiter.
                    try? await Task.sleep(for: wait)
                    await self?.wake(id)
                }
            }
        }
        return try await installToken()
    }

    /// How many ``installToken(awaitingBind:)`` callers wait for a bind now.
    var pendingBindWaiters: Int { bindWaiters.count }

    private func wake(_ id: UUID) { bindWaiters.removeValue(forKey: id)?.resume() }

    private func wakeAll() {
        let waiters = bindWaiters
        bindWaiters = [:]
        for waiter in waiters.values { waiter.resume() }
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
    public func invalidate() async {
        forgetLease()
        await client?.invalidate()
    }

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
        generation &+= 1
        let dropped = client
        client = nil
        user = nil
        forgetLease()
        wakeAll()
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
            profile: .mac, onRecord: { [weak self] record in await self?.recordChanged(record, for: stackUser, generation: bound) },
            now: now
        )
        forgetLease()
        wakeAll()
    }

    private func recordChanged(_ record: InstallRecord?, for stackUser: String, generation bound: UInt64) {
        guard bound == generation else { return }
        store.saveRecord(record, for: stackUser)
    }
}
