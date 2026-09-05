public import Foundation

/// Client identity sent when opening the account-scoped Iroh control session.
///
/// The session ticket is intentionally independent of the endpoint binding
/// proof. The ticket authenticates the already signed-in Stack account to the
/// Cloudflare control plane; the binding proof continues to authorize the
/// individual endpoint mutation or relay mint.
public struct CmxIrohSessionConfiguration: Codable, Equatable, Sendable {
    public let deviceID: String
    public let appInstanceID: String
    public let clientNamespace: String
    public let tag: String
    public let platform: CmxIrohPlatform

    public init(
        deviceID: String,
        appInstanceID: String,
        clientNamespace: String,
        tag: String,
        platform: CmxIrohPlatform
    ) {
        self.deviceID = deviceID
        self.appInstanceID = appInstanceID
        self.clientNamespace = clientNamespace
        self.tag = tag
        self.platform = platform
    }
}
