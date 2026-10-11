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
    public static func defaultReader(environment: [String: String] = ProcessInfo.processInfo.environment) -> any ManagedPreferenceReader {
        #if DEBUG
        if let path = environment[ManagedPreferences.fileOverrideKey], !path.isEmpty {
            return PlistManagedPreferenceReader(url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
        #endif
        return CFManagedPreferenceReader()
    }

    /// Files whose changes mean a profile was installed or removed. macOS
    /// documents no notification for that; these paths are wake-up hints
    /// only (values are always read through CFPreferences).
    public static func watchedFiles(
        userName: String = NSUserName(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        #if DEBUG
        if let path = environment[ManagedPreferences.fileOverrideKey], !path.isEmpty {
            return [URL(fileURLWithPath: (path as NSString).expandingTildeInPath)]
        }
        #endif
        let root = URL(fileURLWithPath: "/Library/Managed Preferences", isDirectory: true)
        let file = "\(ManagedPreferences.domain).plist"
        let legacy = "\(ManagedPreferences.legacyDomain).plist"
        return [
            root.appending(path: file),
            root.appending(path: userName).appending(path: file),
            root.appending(path: legacy),
            root.appending(path: userName).appending(path: legacy)
        ]
    }
}
