import Foundation

/// The review tier of an app's listing version (first-party-apps.md
/// section 4, D51). Copied into the install record, so a tier change (a
/// revoked Verified status) applies at the next grant check.
public nonisolated enum AppTier: String, Sendable, Hashable, Codable, CaseIterable {
    /// Publisher `cmux` (or `manaflow-ai`), built and reviewed in the cmux repo.
    case firstParty
    /// A publisher whose identity cmux verified, with attestation and review.
    case verified
    /// Anyone else: attested release, direct repo install or `local/` app.
    case unverified

    /// The sandbox profile an install starts with.
    public var defaultProfile: AppSandboxProfile {
        switch self {
        case .firstParty, .verified: .standard
        case .unverified: .contained
        }
    }

    /// Whether the install shows a consent sheet (first-party installs
    /// grant required scopes without one and list them in Settings).
    public var showsConsentSheet: Bool { self != .firstParty }
}

/// How a sandbox profile caps a grant (section 5.2). Ordered from the
/// widest to the narrowest: a switch to a later case never widens reach.
public nonisolated enum AppSandboxProfile: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    /// Granted scopes, `net:` hosts and file roots, as granted.
    case standard
    /// Network hosts ask once per session, no files, `execute` and
    /// `external` ask every time, no agents (MCP), local storage only.
    case contained
    /// No network, no files, and only the scopes the user turns on by hand
    /// while the profile is on (all off at first).
    case completeSandbox

    /// 0 = widest. A larger strictness never reaches more.
    public var strictness: Int {
        switch self {
        case .standard: 0
        case .contained: 1
        case .completeSandbox: 2
        }
    }

    public static func < (lhs: AppSandboxProfile, rhs: AppSandboxProfile) -> Bool { lhs.strictness < rhs.strictness }
}

/// The approval mode of one granted scope (identity-and-permissions.md
/// section 4: `none | per_session | per_call`, plus `denied` for a scope
/// the user turned off).
public nonisolated enum AppScopeApproval: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    /// Runs without asking (`none`).
    case always
    /// Asks once per app session (`per_session`).
    case perSession
    /// Asks before every call (`per_call`).
    case perCall
    /// Off: every call is refused with `scope.missing`.
    case denied

    /// 3 = runs without asking, 0 = never runs.
    public var permissiveness: Int {
        switch self {
        case .always: 3
        case .perSession: 2
        case .perCall: 1
        case .denied: 0
        }
    }

    /// The narrower of two modes (the cap a profile puts on a grant).
    public func capped(at cap: AppScopeApproval) -> AppScopeApproval { permissiveness <= cap.permissiveness ? self : cap }

    /// Ordered by permissiveness: `denied < perCall < perSession < always`.
    public static func < (lhs: AppScopeApproval, rhs: AppScopeApproval) -> Bool { lhs.permissiveness < rhs.permissiveness }
}
