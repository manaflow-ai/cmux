import CmuxNextCloud
import CmuxNextDaemon

/// The parent owns credentials; the daemon and app server receive only an opaque scope.
struct CloudCredentialOwner {
    let auth: CloudAuth
    let identity: MacInstallIdentity
    let scope: CloudTeamScope
    let transport: InstallHTTPTransport

    var provider: CloudCredentialProvider {
        let auth = auth, identity = identity, scope = scope, transport = transport
        let headers = identity.requestHeaders
        return CloudCredentialProvider(relay: CloudCredentialRelay(
            post: { path, body, bearer in try await transport.post(path, json: body, bearer: bearer, headers: headers) },
            token: { try await scope.token() }, invalidate: { await identity.invalidate() },
            session: {
                let snapshot = try? await scope.snapshot()
                return CloudCredentialRelay.Session(signedIn: await auth.isSignedIn, team: snapshot?.team,
                    account: snapshot?.account, generation: snapshot?.generation ?? 0, scope: snapshot?.id, requiresScope: true)
            }, allowedOps: { await CloudCredentialRelay.bundledServedOps() }))
    }
}
