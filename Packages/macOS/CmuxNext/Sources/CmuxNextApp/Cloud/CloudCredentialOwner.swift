import CmuxNextCloud
import CmuxNextDaemon

/// The parent owns credentials; the daemon and app server receive only an opaque scope.
struct CloudCredentialOwner {
    let auth: CloudAuth
    let identity: MacInstallIdentity
    let snapshot: @Sendable () async throws -> CloudTeamScope.Snapshot
    let transport: InstallHTTPTransport
    let native: NativeCloudLinkOwner?

    var provider: CloudCredentialProvider {
        let auth = auth, identity = identity, snapshot = snapshot, transport = transport, native = native
        let headers = identity.requestHeaders
        return CloudCredentialProvider(relay: CloudCredentialRelay(
            post: { path, body, bearer in try await transport.post(path, json: body, bearer: bearer, headers: headers) },
            token: { let scope = try await snapshot(); return try await scope.installToken() }, invalidate: { await identity.invalidate() },
            session: {
                let snapshot = try? await snapshot()
                var binding: CloudCredentialNativeLink?
                if let snapshot, let native {
                    do {
                        let socket = try await native.socket(for: snapshot)
                        guard let checked = CloudCredentialNativeLink(scope: snapshot.id, socket: socket) else {
                            return .init(signedIn: await auth.isSignedIn, team: nil, requiresScope: true)
                        }
                        binding = checked
                    } catch {
                        await native.retire()
                        return .init(signedIn: await auth.isSignedIn, team: nil, requiresScope: true)
                    }
                } else if let native {
                    await native.retire()
                }
                return CloudCredentialRelay.Session(signedIn: await auth.isSignedIn, team: snapshot?.team,
                    account: snapshot?.account, generation: snapshot?.generation ?? 0, scope: snapshot?.id, requiresScope: true, nativeLink: binding)
            }, allowedOps: { await CloudCredentialRelay.bundledServedOps() }, ensureNative: { expected in
                guard let native else { throw CloudTeamScope.Failure.unavailable }
                let snapshot = try await snapshot()
                guard snapshot.id == expected else { throw CloudTeamScope.Failure.changed }
                _ = try await native.ensure(snapshot)
                try await snapshot.recheck()
            }))
    }
}
