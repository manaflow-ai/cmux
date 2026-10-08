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
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.install")

    public init(store: MacInstallStore, transport: any InstallAuthTransport, deviceName: String, clientVersion: String?) {
        self.store = store
        self.transport = transport
        self.deviceName = deviceName
        self.clientVersion = clientVersion
    }

    /// Binds `stackUser` at launch from the stored record, without a network
    /// call. `session` is nil when the session is not restored yet: tokens are
    /// still minted from the key, registration waits for ``signedIn``.
    public func restore(stackUser: String, session: InstallAuthClient.SessionToken?) {
        guard user != stackUser else { return }
        bind(stackUser: stackUser, session: session)
    }

    /// The user signed in: binds them and registers (or reuses) the install
    /// at once by minting one token, so a later relay call does not wait.
    public func signedIn(stackUser: String, session: @escaping InstallAuthClient.SessionToken) async throws {
        bind(stackUser: stackUser, session: session)
        _ = try await installToken()
    }

    /// A valid install token for the signed-in user.
    public func installToken() async throws -> String {
        guard let client else { throw Failure.signedOut }
        return try await client.installToken()
    }

    /// The owner refused the current token (401): the next call mints again.
    public func invalidate() async { await client?.invalidate() }

    /// Sign-out (needs the Stack session still): revokes the install on the
    /// server, rotates the key and forgets the record. A failed revoke is
    /// logged; the key and record are forgotten anyway, so this Mac never
    /// mints for that install again.
    public func signOut() async {
        guard let client else { return }
        self.client = nil
        let signedOutUser = user
        user = nil
        do {
            try await client.revoke()
        } catch {
            logger.error("install revoke failed: \(String(describing: error), privacy: .public)")
            await client.reset()
            if let signedOutUser { store.saveRecord(nil, for: signedOutUser) }
            try? await store.signer.rotate()
        }
    }

    private func bind(stackUser: String, session: InstallAuthClient.SessionToken?) {
        user = stackUser
        let store = store
        client = InstallAuthClient(
            transport: transport, signer: store.signer, sessionToken: session, stackUser: stackUser,
            deviceName: deviceName, clientVersion: clientVersion, record: store.record(for: stackUser),
            profile: .mac, onRecord: { record in store.saveRecord(record, for: stackUser) }
        )
    }
}
