public import CmuxInstallAuthCore
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
    /// A retired account stays closed until its session ends. In-flight
    /// cleanup separately fences rebinding even when unbind clears the latch.
    private var signedOutUsers: Set<String> = []
    private var signOutTasks: [String: Task<Void, Never>] = [:]
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.install")

    public init(store: MacInstallStore, transport: any InstallAuthTransport, deviceName: String, clientVersion: String?) {
        self.store = store
        self.transport = transport
        self.deviceName = deviceName
        self.clientVersion = clientVersion
    }

    /// The user signed in: binds them and registers (or reuses) the install
    /// at once by minting one token, so a later relay call does not wait.
    public func signedIn(stackUser: String, session: @escaping InstallAuthClient.SessionToken) async throws {
        guard !signedOutUsers.contains(stackUser), signOutTasks[stackUser] == nil else { throw Failure.signedOut }
        if user != stackUser || client == nil { bind(stackUser: stackUser, session: session) }
        _ = try await installToken()
    }

    /// The headers every install-token request carries (the client
    /// version, so the owner can refuse a too-old app).
    public nonisolated var requestHeaders: [String: String] { InstallAuthClient.headers(clientVersion: clientVersion) }

    /// The `team` claim of an install token (the owner's own token over
    /// TLS; read for consistency, never trusted as a credential). Nil when
    /// the token is not a JWT with a team.
    public nonisolated static func team(ofToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let team = claims["team"] as? String, !team.isEmpty else { return nil }
        return team
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
        let token = try await scoped.installToken()
        guard bound == generation, user == stackUser, await client.currentRecord == record else { throw Failure.signedOut }
        return token
    }

    func nativeContext(team: String) async throws -> NativeInstallContext {
        try await context(team: team)
    }

    /// The bound account for session-only owner reads, never implicit Cloud operation authority.
    func accountContext() async throws -> NativeInstallContext { try await context(team: nil) }

    /// A snapshot retains one scoped client's in-memory refresh cache under the original signer.
    func scopedClient(team: String, context: NativeInstallContext) async throws -> InstallAuthClient {
        try await nativeCheck(context)
        return InstallAuthClient(transport: transport, signer: store.signer(for: context.account), sessionToken: nil,
            stackUser: context.account, deviceName: deviceName, clientVersion: clientVersion,
            record: InstallRecord(user: context.user, install: context.install), profile: .mac,
            team: team, expectedEnvironment: context.environment)
    }

    private func context(team: String?) async throws -> NativeInstallContext {
        guard let client, let stackUser = user else { throw Failure.signedOut }
        let bound = generation
        let token: String
        if let team { token = try await installToken(team: team) } else { token = try await installToken() }
        guard let record = await client.currentRecord, let environment = await client.environment else { throw Failure.signedOut }
        let point = try await store.signer(for: stackUser).publicKeyX963()
        guard bound == generation, user == stackUser, await client.currentRecord == record, point.count == 65, point.first == 4 else { throw Failure.signedOut }
        return NativeInstallContext(account: stackUser, user: record.user, install: record.install, environment: environment,
                                    point: point.base64EncodedString(), token: token, generation: bound, secureStorage: store.usesSecureEnclave)
    }

    func nativeCheck(_ context: NativeInstallContext) async throws {
        guard context.generation == generation, context.account == user, !signedOutUsers.contains(context.account),
              await client?.currentRecord == InstallRecord(user: context.user, install: context.install) else { throw Failure.signedOut }
        guard context.generation == generation, context.account == user, !signedOutUsers.contains(context.account) else { throw Failure.signedOut }
    }

    func nativeSign(_ message: String, context: NativeInstallContext) async throws -> String {
        try await nativeCheck(context)
        let signed = try await store.signer(for: context.account).sign(Data(message.utf8))
        try await nativeCheck(context)
        let signature = signed.count == 64 ? try P256.Signing.ECDSASignature(rawRepresentation: signed) : try P256.Signing.ECDSASignature(derRepresentation: signed)
        return signature.rawRepresentation.base64EncodedString()
    }

    func nativeOwnerPost(_ body: Data, context: NativeInstallContext) async throws -> (status: Int, body: Data) {
        try await nativeCheck(context)
        let reply = try await transport.post("/v1/ops", json: body, bearer: context.token, headers: requestHeaders)
        try await nativeCheck(context)
        return reply
    }

    func nativeOwnerRead(_ body: Data, context: NativeInstallContext) async throws -> (status: Int, body: Data) {
        try await nativeCheck(context)
        let reply = try await transport.post("/v1/read", json: body, bearer: context.token, headers: requestHeaders)
        try await nativeCheck(context)
        return reply
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
        signedOutUsers.removeAll()
        await drop()
    }

    /// Stops the bound client: no record write, no token from a mint in flight.
    private func drop() async {
        let dropped = releaseClient()
        await dropped?.reset()
    }

    /// Detaches synchronously before any reset can suspend and allow a new binding.
    private func releaseClient() -> InstallAuthClient? {
        generation &+= 1
        let dropped = client
        client = nil
        user = nil
        return dropped
    }

    /// Sign-out of `stackUser` (needs the Stack session still): revokes the
    /// install on the server, also one stored by an earlier launch that this
    /// one never bound, then always rotates the user's key and forgets the
    /// record, so this Mac never mints for that install again, also when the
    /// revoke failed or a registration was still in flight. Until the session
    /// ends (``unbind()``) this account cannot register again. A different
    /// account's client and key are independent of the retiring account.
    public func signOut(stackUser signedOutUser: String, session: @escaping InstallAuthClient.SessionToken) async {
        if let ending = signOutTasks[signedOutUser] { await ending.value; return }
        signedOutUsers.insert(signedOutUser)
        let dropped = user == signedOutUser ? releaseClient() : nil
        let record = store.record(for: signedOutUser)
        // task-owner: signOutTasks; concurrent calls join it, including across unbind.
        let ending = Task {
            await dropped?.reset()
            await revokeInstall(stackUser: signedOutUser, record: record, session: session)
        }
        signOutTasks[signedOutUser] = ending
        await ending.value
        signOutTasks[signedOutUser] = nil
    }

    private func revokeInstall(stackUser signedOutUser: String, record: InstallRecord?, session: @escaping InstallAuthClient.SessionToken) async {
        let client = InstallAuthClient(
            transport: transport, signer: store.signer(for: signedOutUser), sessionToken: session, stackUser: signedOutUser,
            deviceName: deviceName, clientVersion: clientVersion, record: record, profile: .mac
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
