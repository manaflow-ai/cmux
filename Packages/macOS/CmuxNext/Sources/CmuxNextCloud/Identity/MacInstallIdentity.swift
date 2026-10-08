public import CmuxInstallAuthCore
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
        if user != stackUser || client == nil { bind(stackUser: stackUser, session: session) }
        _ = try await installToken()
    }

    /// A valid install token for the signed-in user.
    public func installToken() async throws -> String {
        guard let client else { throw Failure.signedOut }
        return try await client.installToken()
    }

    /// The owner refused the current token (401): the next call mints again.
    public func invalidate() async { await client?.invalidate() }

    /// The session ended without a sign-out here (expired, or signed out
    /// elsewhere): stop minting. The key and record stay, so a sign-in of the
    /// same user reuses the install and a later sign-out can still revoke it.
    public func unbind() {
        generation &+= 1
        client = nil
        user = nil
    }

    /// Sign-out (needs the Stack session still): revokes the install on the
    /// server, then always rotates the user's key and forgets the record, so
    /// this Mac never mints for that install again, also when the revoke
    /// failed or a registration was still in flight.
    public func signOut() async {
        guard let client, let signedOutUser = user else { return }
        unbind()
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
