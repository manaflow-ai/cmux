public import CmuxNextCloud
public import CmuxNextDaemon
public import Foundation

public nonisolated extension CloudCredentialRelay {
    /// One install-bound relay shared by the app provider and private link carrier.
    static func live(identity: MacInstallIdentity, baseURL: URL, capability: CloudCapabilityHolder? = nil,
                     signedIn: @escaping @Sendable () async -> Bool,
                     allowedOps: @escaping @Sendable () async -> Set<String>,
                     carrierSocket: @escaping CarrierSocket = CloudCredentialRelay.noCarrier) -> CloudCredentialRelay {
        let transport = InstallHTTPTransport(baseURL: baseURL)
        let headers = identity.requestHeaders
        return CloudCredentialRelay(
            // The person's pre-approval rides on every call (cmux-platform#1126); none held, the server checks in full.
            post: { path, body, bearer in
                let approved = await capability?.headers(installToken: bearer) ?? [:]
                return try await transport.post(path, json: body, bearer: bearer, headers: headers.merging(approved) { $1 })
            },
            token: { try await identity.installToken() },
            invalidate: { await capability?.drop(); await identity.invalidate() },
            session: {
                guard await signedIn() else { return Session(signedIn: false, team: nil) }
                // Bill the install token's backend team, never the Stack team ID.
                let token = try? await identity.installToken()
                return Session(signedIn: true, team: token.flatMap(MacInstallIdentity.team(ofToken:)))
            },
            allowedOps: allowedOps,
            carrierSocket: carrierSocket)
    }
}
