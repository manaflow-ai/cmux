public import Foundation

/// Chrome's `IntranetRedirectBehavior` policy as a company set it for Chrome
/// (the `com.google.Chrome` managed domain an MDM profile fills), so cmux's
/// bare-word intranet check follows the same rule with no cmux setup
/// (the browser's `IntranetRedirectBehavior(policyValue:)`).
public nonisolated struct ChromeIntranetPolicy {
    public static let domain = "com.google.Chrome"
    public static let key = "IntranetRedirectBehavior"

    let reader: any ManagedPreferenceReader

    public init(reader: any ManagedPreferenceReader = CFManagedPreferenceReader(domain: ChromeIntranetPolicy.domain, keys: [ChromeIntranetPolicy.key])) {
        self.reader = reader
    }

    /// The managed value (forced first, then recommended); nil when unset or not an integer.
    public func policyValue() -> Int? {
        let preferences = reader.read()
        guard case .number(let value)? = preferences.forced[Self.key] ?? preferences.recommended[Self.key] else { return nil }
        return Int(exactly: value)
    }
}
