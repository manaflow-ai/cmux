/// Authentication a user can request for a custom Iroh relay.
public enum CmxIrohCustomRelayCredentialMode: String, Equatable, Sendable {
    /// The relay accepts connections without an application credential.
    case none

    /// This device must keep a provider-issued secret in secure storage.
    case deviceSecret
}

/// Editable, non-secret metadata for one custom Iroh relay.
public struct CmxIrohCustomRelayDraft: Equatable, Sendable {
    /// Stable account-scoped identifier. Empty when creating a relay.
    public let id: String?
    public let displayName: String
    public let provider: String
    public let region: String
    public let url: String
    public let authMode: CmxIrohCustomRelayCredentialMode

    public init(
        id: String? = nil,
        displayName: String,
        provider: String,
        region: String,
        url: String,
        authMode: CmxIrohCustomRelayCredentialMode
    ) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
        self.region = region
        self.url = url
        self.authMode = authMode
    }
}
