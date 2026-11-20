public import Foundation

/// A managed policy key that is not a cmux.json setting.
public nonisolated struct ManagedPolicyKey: Sendable, Hashable {
    public enum ValueType: Sendable, Hashable {
        case string
        case boolean
        case choice([String])
        case stringArray([String])
    }

    public let name: String
    public let type: ValueType
    public let help: String

    public init(_ name: String, type: ValueType, help: String) {
        self.name = name
        self.type = type
        self.help = help
    }
}

/// Where managed preferences come from on this machine.
public nonisolated enum ManagedPreferenceLocation {
    /// DEV builds honor `CMUX_NEXT_MANAGED_PREFS_FILE`; release builds always
    /// read the CFPreferences domain, so an environment variable cannot
    /// override an administrator's profile.
    ///
    /// `keys` limits cmux's own domain to those keys; nil reads every published key
    /// (``CFManagedPreferenceReader/readKeys``), which builds the whole settings catalog
    /// (``SettingsSchema/all``, about 50 ms with its localized strings). A reader in `main`,
    /// before AppKit reports the launch finished (the Dock's bounce), names its keys.
    public static func defaultReader(environment: [String: String] = ProcessInfo.processInfo.environment,
                                     keys: [String]? = nil) -> any ManagedPreferenceReader {
        let cfReader = { keys.map { CFManagedPreferenceReader(keys: $0) } ?? CFManagedPreferenceReader() }
        #if DEBUG
        let chromeFile = environment[ChromePolicyDocument.fileOverrideKey].flatMap { $0.isEmpty ? nil : $0 }
        let chrome: any ChromePolicyReading = chromeFile.map { PlistChromePolicyReader(url: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)) }
            ?? CFChromePolicyReader()
        let cmuxBrowser: any ChromePolicyReading = chromeFile == nil
            ? CFChromePolicyReader(domain: ChromePolicyDocument.cmuxDomain) : FixedChromePolicyReader(.empty)
        if let path = environment[ManagedPreferences.fileOverrideKey], !path.isEmpty {
            let cmux = PlistManagedPreferenceReader(url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            return ChromePolicyManagedPreferenceReader(cmux: cmux, chrome: chrome, cmuxBrowser: cmuxBrowser)
        }
        return ChromePolicyManagedPreferenceReader(cmux: cfReader(), chrome: chrome, cmuxBrowser: cmuxBrowser)
        #else
        return ChromePolicyManagedPreferenceReader(cmux: cfReader())
        #endif
    }

    /// Files whose changes mean a profile was installed or removed. macOS
    /// documents no notification for that; these paths are wake-up hints
    /// only (values are always read through CFPreferences).
    public static func watchedFiles(
        userName: String = NSUserName(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        #if DEBUG
        let overrides = [ManagedPreferences.fileOverrideKey, ChromePolicyDocument.fileOverrideKey]
            .compactMap { environment[$0] }.filter { !$0.isEmpty }
        if !overrides.isEmpty {
            return overrides.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        }
        #endif
        let root = URL(fileURLWithPath: "/Library/Managed Preferences", isDirectory: true)
        let file = "\(ManagedPreferences.domain).plist"
        let legacy = "\(ManagedPreferences.legacyDomain).plist"
        let chrome = "\(ChromePolicyDocument.chromeDomain).plist"
        let browser = "\(ChromePolicyDocument.cmuxDomain).plist"
        return [file, legacy, chrome, browser].flatMap { name in
            [root.appending(path: name), root.appending(path: userName).appending(path: name)]
        }
    }
}
