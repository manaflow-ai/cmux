/// One account row from `GET /_subrouter/usage-status`: account identity,
/// auth-check outcome, active marker, plan tier, quota windows, and credits.
///
/// The daemon embeds its account-status struct, so all fields arrive
/// flattened in one snake_case JSON object — except `windows` and `credits`,
/// whose element keys are PascalCase (see ``SubrouterUsageWindow``).
///
/// The `active` key is `omitempty` on the wire: it is present only when
/// `true`, so a missing key decodes as `false`. This is also the **only**
/// endpoint that reports which account is active per provider.
public struct SubrouterAccountUsageStatus: Sendable, Hashable, Codable, Identifiable {
    /// The daemon's account id: the Codex account email, or the Claude
    /// profile name.
    public var id: String
    /// The provider namespace the account belongs to.
    public var provider: SubrouterProvider
    /// How the account authenticates.
    public var authMode: SubrouterAuthMode
    /// The account email when known, else `nil`.
    public var email: String?
    /// The on-disk source path of the stored auth metadata (never a secret).
    public var source: String
    /// Whether the daemon performed an auth check for this row.
    public var authChecked: Bool
    /// Whether the auth check succeeded. Meaningful only when
    /// ``authChecked`` is `true`.
    public var authValid: Bool
    /// Whether the daemon refreshed the account's token during the check.
    public var refreshed: Bool
    /// A transient per-account fetch error from the daemon, else `nil`.
    public var errorDescription: String?
    /// Whether this is the provider's currently active account.
    public var isActive: Bool
    /// The plan tier (e.g. `"pro"`, `"plus"`; `"api key"` for Codex API-key
    /// accounts, `"claude"` for Claude profiles), else `nil`.
    public var planType: String?
    /// The live quota windows, empty when unavailable.
    public var windows: [SubrouterUsageWindow]
    /// The Codex credit balance, `nil` for non-Codex accounts.
    public var credits: SubrouterCredits?

    private enum CodingKeys: String, CodingKey {
        case id
        case provider
        case authMode = "auth_mode"
        case email
        case source
        case authChecked = "auth_checked"
        case authValid = "auth_valid"
        case refreshed
        case errorDescription = "error"
        case isActive = "active"
        case planType = "plan_type"
        case windows
        case credits
    }

    /// Creates a usage-status row.
    /// - Parameters:
    ///   - id: The daemon's account id.
    ///   - provider: The provider namespace.
    ///   - authMode: How the account authenticates.
    ///   - email: The account email when known.
    ///   - source: The stored-auth source path.
    ///   - authChecked: Whether an auth check ran.
    ///   - authValid: Whether the auth check succeeded.
    ///   - refreshed: Whether the token was refreshed.
    ///   - errorDescription: A transient per-account fetch error.
    ///   - isActive: Whether this is the provider's active account.
    ///   - planType: The plan tier.
    ///   - windows: The live quota windows.
    ///   - credits: The Codex credit balance.
    public init(
        id: String,
        provider: SubrouterProvider,
        authMode: SubrouterAuthMode = .oauth,
        email: String? = nil,
        source: String = "",
        authChecked: Bool = false,
        authValid: Bool = false,
        refreshed: Bool = false,
        errorDescription: String? = nil,
        isActive: Bool = false,
        planType: String? = nil,
        windows: [SubrouterUsageWindow] = [],
        credits: SubrouterCredits? = nil
    ) {
        self.id = id
        self.provider = provider
        self.authMode = authMode
        self.email = email
        self.source = source
        self.authChecked = authChecked
        self.authValid = authValid
        self.refreshed = refreshed
        self.errorDescription = errorDescription
        self.isActive = isActive
        self.planType = planType
        self.windows = windows
        self.credits = credits
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Identity is load-bearing: it is the SwiftUI row identity and the
        // account id handed to `sr switch`. A row without it must fail the
        // decode closed instead of synthesizing an empty id that several
        // malformed rows would share (and that a switch could target).
        let id = try container.decode(String.self, forKey: .id)
        let provider = try container.decode(SubrouterProvider.self, forKey: .provider)
        guard !id.isEmpty, !provider.rawValue.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: id.isEmpty ? .id : .provider,
                in: container,
                debugDescription: "usage-status row is missing its account identity"
            )
        }
        self.id = id
        self.provider = provider
        self.authMode = try container.decodeIfPresent(SubrouterAuthMode.self, forKey: .authMode)
            ?? SubrouterAuthMode(rawValue: "")
        self.email = try container.decodeIfPresent(String.self, forKey: .email)
        self.source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        self.authChecked = try container.decodeIfPresent(Bool.self, forKey: .authChecked) ?? false
        self.authValid = try container.decodeIfPresent(Bool.self, forKey: .authValid) ?? false
        self.refreshed = try container.decodeIfPresent(Bool.self, forKey: .refreshed) ?? false
        self.errorDescription = try container.decodeIfPresent(String.self, forKey: .errorDescription)
        self.isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        self.planType = try container.decodeIfPresent(String.self, forKey: .planType)
        self.windows = try container.decodeIfPresent([SubrouterUsageWindow].self, forKey: .windows) ?? []
        self.credits = try container.decodeIfPresent(SubrouterCredits.self, forKey: .credits)
    }
}

extension SubrouterAccountUsageStatus {
    /// The cooked/temp-cooked assessment derived from ``windows``.
    public var quotaAssessment: SubrouterQuotaAssessment {
        SubrouterQuotaAssessment.assess(windows)
    }

    /// The display label: the email when known, else the account id.
    public var displayName: String {
        email ?? id
    }

    /// Whether this account needs user attention: it is cooked or
    /// temp-cooked, a quota window is nearly exhausted, or its auth check
    /// failed.
    public var needsAttention: Bool {
        if quotaAssessment != .ok { return true }
        if windows.contains(where: { $0.isNearlyExhausted }) { return true }
        if authChecked && !authValid { return true }
        return false
    }

    /// The most consumed quota window — the one that will limit the account
    /// first — or `nil` when no usage data is available.
    public var constrainingWindow: SubrouterUsageWindow? {
        windows.max { $0.usedPercent < $1.usedPercent }
    }

    /// Orders switch candidates most-headroom-first: ascending by the
    /// constraining window's used percentage, accounts without usage data
    /// last, ties broken by id for stability across refreshes.
    public static func sortedByHeadroom(
        _ accounts: [SubrouterAccountUsageStatus]
    ) -> [SubrouterAccountUsageStatus] {
        accounts.sorted { lhs, rhs in
            switch (lhs.constrainingWindow?.usedPercent, rhs.constrainingWindow?.usedPercent) {
            case (nil, nil):
                return lhs.id < rhs.id
            case (nil, _):
                return false
            case (_, nil):
                return true
            case (let l?, let r?):
                if l != r { return l < r }
                return lhs.id < rhs.id
            }
        }
    }
}
