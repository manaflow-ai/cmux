public import Foundation

/// The AI providers whose usage the HUD can surface. Raw values match
/// `RestorableAgentKind.rawValue` in the host app so a live agent surface can be
/// mapped to a provider without a translation table.
public enum UsageProvider: String, Sendable, CaseIterable, Hashable {
    case claude
    case codex
    case grok
    case kimi
    case gemini

    /// Human-facing name; localized by the host app at the view layer.
    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .kimi: return "Kimi"
        case .gemini: return "Gemini"
        }
    }
}

/// One rolling quota window (or a credit balance) reported by a provider.
public struct UsageWindow: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A rolling window of `seconds` length (e.g. 18000 = 5h, 604800 = 7d).
        case rolling(seconds: Int)
        /// A monetary/credit balance rather than a time window.
        case credits
    }

    public var kind: Kind
    /// 0…100, `nil` when the provider only exposes a credit balance.
    public var usedPercent: Double?
    /// Absolute instant this window resets, if the provider reports one.
    public var resetAt: Date?
    /// Remaining credits for `.credits` windows, if reported.
    public var creditsRemaining: Double?

    public init(
        kind: Kind,
        usedPercent: Double? = nil,
        resetAt: Date? = nil,
        creditsRemaining: Double? = nil
    ) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetAt = resetAt
        self.creditsRemaining = creditsRemaining
    }
}

/// Identity of a single provider account (a provider may in principle have more
/// than one). `id` is stable across fetches so the HUD can key snapshots by it.
public struct ProviderAccount: Sendable, Equatable, Hashable {
    public var provider: UsageProvider
    /// Provider-scoped account identifier (never a token or secret).
    public var accountId: String
    /// Optional label the provider surfaces (email, plan owner, …). Non-secret.
    public var displayLabel: String?

    public init(provider: UsageProvider, accountId: String, displayLabel: String? = nil) {
        self.provider = provider
        self.accountId = accountId
        self.displayLabel = displayLabel
    }
}

/// How trustworthy/current a snapshot is. Drives the HUD's per-row badge.
public enum UsageFreshness: Sendable, Equatable {
    /// Fetched successfully at the given instant.
    case live(Date)
    /// Showing a prior value; the current token is expired and its CLI is idle.
    case stale(since: Date?)
    /// The provider is installed but not signed in (no usable credential).
    case signedOut
    /// The provider CLI isn't installed on this machine.
    case notInstalled
    /// The provider exposes no usage/limits surface cmux can read.
    case unsupported
    /// The provider is rate-limiting; do not poll again before `until`.
    case rateLimited(until: Date)
}

/// Immutable, `Sendable` snapshot of one account's usage. The HUD only ever holds
/// value copies of these — never a reference to a mutable store below a list boundary.
public struct UsageSnapshot: Sendable, Equatable {
    public var account: ProviderAccount
    /// Provider plan label (e.g. "plus", "max"), if reported. Non-secret.
    public var planLabel: String?
    public var windows: [UsageWindow]
    public var freshness: UsageFreshness
    public var fetchedAt: Date

    public init(
        account: ProviderAccount,
        planLabel: String? = nil,
        windows: [UsageWindow],
        freshness: UsageFreshness,
        fetchedAt: Date
    ) {
        self.account = account
        self.planLabel = planLabel
        self.windows = windows
        self.freshness = freshness
        self.fetchedAt = fetchedAt
    }
}

/// Errors an adapter can raise. Kept coarse; callers map to `UsageFreshness`.
public enum UsageAdapterError: Error, Sendable, Equatable {
    /// No usable credential found (file/keychain absent or token unreadable).
    case signedOut
    /// The provider isn't installed on this machine.
    case notInstalled
    /// HTTP call failed with a status code.
    case httpStatus(Int)
    /// The provider is rate-limiting (HTTP 429/403 on a usage endpoint).
    case rateLimited
    /// Response body did not match the expected schema (hostile-input guard).
    case malformedResponse
    /// This provider has no readable usage surface.
    case unsupported
}
