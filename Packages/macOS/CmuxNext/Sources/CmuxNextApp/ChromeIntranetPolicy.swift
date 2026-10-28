import CmuxNextBrowser
import CmuxNextSettings

/// Chrome's `IntranetRedirectBehavior` policy as a company set it for Chrome
/// (the `com.google.Chrome` managed domain an MDM profile fills), so cmux's
/// bare-word intranet check follows the same rule with no cmux setup.
nonisolated struct ChromeIntranetPolicy {
    static let domain = "com.google.Chrome"
    static let key = "IntranetRedirectBehavior"

    let reader: any ManagedPreferenceReader

    init(reader: any ManagedPreferenceReader = CFManagedPreferenceReader(domain: ChromeIntranetPolicy.domain, keys: [ChromeIntranetPolicy.key])) {
        self.reader = reader
    }

    /// The managed value (forced first, then recommended); the default 3 when unset.
    func behavior() -> IntranetRedirectBehavior {
        let preferences = reader.read()
        guard case .number(let value)? = preferences.forced[Self.key] ?? preferences.recommended[Self.key] else {
            return IntranetRedirectBehavior(policyValue: nil)
        }
        return IntranetRedirectBehavior(policyValue: Int(exactly: value))
    }
}
