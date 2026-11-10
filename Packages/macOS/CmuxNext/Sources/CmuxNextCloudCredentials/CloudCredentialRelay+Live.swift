public import CmuxNextCloud
public import CmuxNextDaemon
public import Foundation

public nonisolated extension CloudCredentialRelay {
    /// One install-bound relay shared by the app provider and private link carrier. Each op it posts carries
    /// the signed Cloud capability the identity holds for the install token's team (cmux-platform#1126).
    static func live(identity: MacInstallIdentity, baseURL: URL,
                     signedIn: @escaping @Sendable () async -> Bool,
                     allowedOps: @escaping @Sendable () async -> Set<String>,
                     carrierSocket: @escaping CarrierSocket = CloudCredentialRelay.noCarrier) -> CloudCredentialRelay {
        let transport = InstallHTTPTransport(baseURL: baseURL)
        let headers = identity.requestHeaders
        return CloudCredentialRelay(
            post: CloudCapabilityHolder.relayPost(transport: transport, headers: headers, capability: identity.capability),
            token: { try await identity.installToken() },
            invalidate: { await identity.invalidate() },
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
