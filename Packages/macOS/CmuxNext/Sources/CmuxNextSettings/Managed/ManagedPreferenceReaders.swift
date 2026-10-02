public import Foundation

/// Reads the managed domain through CFPreferences (what MDM profiles feed;
/// cfprefsd merges the device and user channels). Only keys in the
/// published schema are honored: the settings catalog plus the policy keys.
public nonisolated struct CFManagedPreferenceReader: ManagedPreferenceReader {
    public let domain: String
    public let keys: [String]

    public init(domain: String = ManagedPreferences.domain, keys: [String] = CFManagedPreferenceReader.publishedKeys) {
        self.domain = domain
        self.keys = keys
    }

    /// Every key the published schema lists (docs/mdm).
    public static var publishedKeys: [String] {
        SettingsSchema.all.map(\.id) + ManagedPreferences.policyKeys.map(\.name)
    }

    public func read() -> ManagedPreferences {
        var result = ManagedPreferences()
        let app = domain as CFString
        CFPreferencesAppSynchronize(app)
        for key in keys {
            guard let raw = CFPreferencesCopyAppValue(key as CFString, app),
                  let value = ManagedPreferences.json(fromPropertyList: raw) else { continue }
            if CFPreferencesAppValueIsForced(key as CFString, app) {
                result.forced[key] = value
            } else {
                result.recommended[key] = value
            }
        }
        let legacy = ManagedPreferences.legacyDomain as CFString
        CFPreferencesAppSynchronize(legacy)
        for key in ManagedPreferences.legacyKeys where result.forced[key] == nil {
            // The legacy domain is the app's own domain, so only forced values count.
            guard CFPreferencesAppValueIsForced(key as CFString, legacy),
                  let raw = CFPreferencesCopyAppValue(key as CFString, legacy),
                  let value = ManagedPreferences.json(fromPropertyList: raw) else { continue }
            result.forced[key] = value
        }
        return result
    }
}

/// Reads a plist file shaped like a profile payload, for DEV builds and
/// tests: top-level keys are forced, keys under a top-level `Recommended`
/// dictionary are recommended. A missing or unreadable file is empty.
public nonisolated struct PlistManagedPreferenceReader: ManagedPreferenceReader {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func read() -> ManagedPreferences {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return .empty }
        var result = ManagedPreferences()
        for (key, raw) in plist {
            if key == "Recommended", let nested = raw as? [String: Any] {
                result.recommended = nested.compactMapValues { ManagedPreferences.json(fromPropertyList: $0) }
            } else if let value = ManagedPreferences.json(fromPropertyList: raw) {
                result.forced[key] = value
            }
        }
        return result
    }
}

/// Fixed values (tests, previews).
public nonisolated struct FixedManagedPreferenceReader: ManagedPreferenceReader {
    public let preferences: ManagedPreferences

    public init(_ preferences: ManagedPreferences) {
        self.preferences = preferences
    }

    public func read() -> ManagedPreferences { preferences }
}
