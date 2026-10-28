public import Foundation

/// Reads a Chrome policy domain through CFPreferences, as Chrome does on
/// macOS: a forced value (MDM profile, Chrome Enterprise cloud policy) is
/// mandatory, any other value recommended. Only ``ChromePolicyDocument/mappedKeys``
/// (and ``ChromePolicyDocument/honorChromePolicyKey``) are read; Chromium
/// reads the rest of the domain itself.
public nonisolated struct CFChromePolicyReader: ChromePolicyReading {
    public let domain: String
    public let keys: [String]

    public init(domain: String = ChromePolicyDocument.chromeDomain,
                keys: [String] = ChromePolicyDocument.mappedKeys + [ChromePolicyDocument.honorChromePolicyKey]) {
        self.domain = domain
        self.keys = keys
    }

    public func read() -> ChromePolicyDocument {
        var result = ChromePolicyDocument()
        let app = domain as CFString
        CFPreferencesAppSynchronize(app)
        for key in keys {
            guard let raw = CFPreferencesCopyAppValue(key as CFString, app),
                  let value = ManagedPreferences.json(fromPropertyList: raw) else { continue }
            if CFPreferencesAppValueIsForced(key as CFString, app) {
                result.mandatory[key] = value
            } else {
                result.recommended[key] = value
            }
        }
        return result
    }
}
