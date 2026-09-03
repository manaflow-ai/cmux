import Foundation

/// Where a next-transport client earns its relay admission: the trust
/// broker origin, the Stack Auth deployment that authenticates the account,
/// and the credential mode the relay fleet expects. One value replaces the
/// staging constants both app call sites used to hardcode inline, so the
/// Mac host and the iOS dialer construct the same broker flow from one
/// definition instead of two copies that can drift.
public struct NextTransportEnvironment: Sendable {
    /// Trust broker origin (`/api/devices/iroh/*`, `/api/relay/token`).
    public var brokerBaseURL: URL
    /// Stack Auth origin for password sign-in (dev harness mode).
    public var stackAuthBaseURL: URL
    /// Stack Auth project this deployment authenticates against.
    public var stackProjectID: String
    /// Stack Auth publishable client key. A public client identifier by
    /// design (`pck_` prefix), not a secret.
    public var stackPublishableClientKey: String
    /// How this fleet admits endpoints. `.tokenMinting` is today's deployed
    /// contract; callers read this to decide whether to run a mint/renewal
    /// schedule at all (`RelayCredentialMode.requiresClientCredential`).
    public var credentialMode: RelayCredentialMode

    public init(
        brokerBaseURL: URL,
        stackAuthBaseURL: URL,
        stackProjectID: String,
        stackPublishableClientKey: String,
        credentialMode: RelayCredentialMode = .tokenMinting
    ) {
        self.brokerBaseURL = brokerBaseURL
        self.stackAuthBaseURL = stackAuthBaseURL
        self.stackProjectID = stackProjectID
        self.stackPublishableClientKey = stackPublishableClientKey
        self.credentialMode = credentialMode
    }

    /// The staging deployment, byte-for-byte the values previously
    /// hardcoded in `MobileHostNextTransportRuntime.brokerClient` (Mac) and
    /// `NextTransportDialClient.brokerClient` (iOS).
    public static let staging = NextTransportEnvironment(
        brokerBaseURL: URL(string: "https://cmux-staging.vercel.app")!,
        stackAuthBaseURL: URL(string: "https://api.stack-auth.com")!,
        stackProjectID: "454ecd03-1db2-4050-845e-4ce5b0cd9895",
        stackPublishableClientKey: "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g",
        credentialMode: .tokenMinting)
}
