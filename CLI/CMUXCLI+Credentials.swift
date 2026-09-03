import Foundation
import CmuxCLISocketAuth

extension CMUXCLI {
    /// Warms the OpenTUI child through the lazy socket-auth path.
    ///
    /// The first Feed request is deliberately made before launching the child
    /// because the JavaScript client can only receive a password through its
    /// environment. An allow-all response leaves the resolver untouched.
    func warmOpenTUIFeedAuthentication(
        socketPath: String,
        socketPassword: String?,
        credentialResolver: SocketCredentialResolver?
    ) -> String? {
        guard let credentialResolver else { return socketPassword }
        let client = SocketClient(path: socketPath)
        defer { client.close() }
        do {
            try client.connect()
            try authenticateClientIfNeeded(
                client,
                explicitPassword: socketPassword,
                socketPath: socketPath,
                responseTimeout: 2,
                credentialResolver: credentialResolver
            )
            _ = try client.sendV2(
                method: "feed.list",
                params: ["pending_only": true],
                responseTimeout: 2
            )
            return credentialResolver.resolvedPassword ?? socketPassword
        } catch {
            return credentialResolver.resolvedPassword ?? socketPassword
        }
    }
}
