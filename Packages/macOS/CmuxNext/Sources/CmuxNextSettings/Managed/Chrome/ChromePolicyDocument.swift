public import Foundation

/// Chrome enterprise policies an organization deployed for Google Chrome
/// (plans/cmux-next/chrome-enterprise-policy-DESIGN.md). Keys are Chrome's
/// policy names (`URLBlocklist`, `DefaultSearchProviderSearchURL`, ...).
/// `mandatory` holds forced values (an MDM profile, Chrome Enterprise
/// cloud policy written by Chrome's management agent); `recommended` holds
/// values the user may change, as Chrome reads them.
public nonisolated struct ChromePolicyDocument: Sendable, Equatable {
    public var mandatory: [String: JSONValue]
    public var recommended: [String: JSONValue]

    public init(mandatory: [String: JSONValue] = [:], recommended: [String: JSONValue] = [:]) {
        self.mandatory = mandatory
        self.recommended = recommended
    }

    public static let empty = ChromePolicyDocument()

    /// Google Chrome's managed preference domain (`/Library/Managed Preferences/com.google.Chrome.plist`).
    public static let chromeDomain = "com.google.Chrome"
    /// cmux's own browser policy domain: the same Chrome policy names, for an
    /// organization that manages cmux apart from Chrome. Its values win over
    /// Chrome's, key by key.
    public static let cmuxDomain = "com.manaflow.cmux.browser"
    /// In ``cmuxDomain``: a forced `false` makes cmux ignore Chrome's domain
    /// (the cmux domain still applies). Absent or `true` honors Chrome's.
    public static let honorChromePolicyKey = "HonorChromePolicy"
    /// DEV and test builds read Chrome policies from this plist instead of both domains.
    public static let fileOverrideKey = "CMUX_NEXT_CHROME_POLICY_FILE"

    /// Chrome policies cmux maps onto its own settings or enforces itself.
    /// Chromium reads every other Chrome policy natively (the design doc's matrix).
    public static let mappedKeys: [String] = [
        "DefaultSearchProviderEnabled", "DefaultSearchProviderSearchURL", "DefaultSearchProviderSuggestURL",
        "DefaultSearchProviderName", "NewTabPageLocation", "PasswordManagerEnabled",
        "URLBlocklist", "URLAllowlist", "ExtensionInstallForcelist",
    ]

    public var isEmpty: Bool { mandatory.isEmpty && recommended.isEmpty }

    /// The domain Chromium reads Chrome policies from natively
    /// (CefSettings.chrome_policy_id): Chrome's, unless `cmuxBrowser` (the
    /// ``cmuxDomain`` document) forces `HonorChromePolicy` to false.
    public static func nativePolicyDomain(cmuxBrowser: ChromePolicyDocument) -> String? {
        nil  // red: Chromium reads no policy yet
    }

    /// This document with `other`'s values on top, key by key in each level.
    public func overlaid(by other: ChromePolicyDocument) -> ChromePolicyDocument {
        ChromePolicyDocument(mandatory: mandatory.merging(other.mandatory) { $1 },
                             recommended: recommended.merging(other.recommended) { $1 })
    }
}
