import Foundation

/// The local sign-in state of one provider on this Mac.
public enum LocalAuthStatus: String, Sendable, Equatable, Codable {
    /// A usable sign-in or key exists (for a local server: it answers).
    case signedIn = "signed_in"
    /// A sign-in exists but can no longer renew itself.
    case expired
    /// Nothing found.
    case missing
    /// Something exists that cmux cannot read without a secret or a prompt
    /// (an unreadable file, an unknown format).
    case unknown
}

/// Where a detection came from. Values name a place, never a secret: a
/// display path with `~`, an environment variable name, a Keychain service.
public enum DetectionSource: Sendable, Equatable, Hashable {
    case file(String)
    case environment(String)
    case keychain(String)
    /// A key the user saved in cmux's own Keychain item.
    case cmuxKeychain
    case server(String)

    public var label: String {
        switch self {
        case .file(let path): path
        case .environment(let key): "$" + key
        case .keychain(let service): service
        case .cmuxKeychain: "cmux Keychain"
        case .server(let address): address
        }
    }
}

/// One provider's detection result. `identity` and `plan` are shown only
/// when the source exposes them as plain, non-secret fields (an email, a
/// plan name, a profile name); a credential value is never kept here.
public struct ProviderDetection: Sendable, Equatable {
    public var provider: AIProvider
    public var status: LocalAuthStatus
    public var identity: String?
    public var plan: String?
    public var sources: [DetectionSource]

    public init(provider: AIProvider, status: LocalAuthStatus, identity: String? = nil, plan: String? = nil,
                sources: [DetectionSource] = []) {
        self.provider = provider
        self.status = status
        self.identity = identity
        self.plan = plan
        self.sources = sources
    }

    public static func missing(_ provider: AIProvider) -> ProviderDetection {
        ProviderDetection(provider: provider, status: .missing)
    }
}
