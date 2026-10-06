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
/// An email inside a path is shortened when the source is made
/// (``DetectionEnvironment/display(_:)``).
public enum DetectionSource: Sendable, Equatable, Hashable, Encodable {
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

/// One provider's detection result. A credential value is never kept
/// here, and neither is an email or login: the signed-in account is an
/// ``AccountLabel`` (an opaque handle and a redacted display), made inside
/// the detector from the raw identity, which is then dropped.
public struct ProviderDetection: Sendable, Equatable, Encodable {
    public var provider: AIProvider
    public var status: LocalAuthStatus
    /// The signed-in account, when the source names one.
    public let account: AccountLabel?
    /// A non-personal fact: a local server address, an AWS profile name, a
    /// credential type. Emails inside it are shortened.
    public let detail: String?
    /// A plan, organization, region or project name. Emails inside it are shortened.
    public let plan: String?
    public var sources: [DetectionSource]

    public init(provider: AIProvider, status: LocalAuthStatus, account: AccountLabel? = nil, detail: String? = nil,
                plan: String? = nil, sources: [DetectionSource] = []) {
        self.provider = provider
        self.status = status
        self.account = account
        self.detail = detail.map(EmailRedaction.redactEmails(in:))
        self.plan = plan.map(EmailRedaction.redactEmails(in:))
        self.sources = sources
    }

    public static func missing(_ provider: AIProvider) -> ProviderDetection {
        ProviderDetection(provider: provider, status: .missing)
    }
}
