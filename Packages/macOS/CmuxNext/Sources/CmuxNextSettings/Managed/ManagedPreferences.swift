public import Foundation

/// Who manages a settings key (spec/enterprise.md 4.4): the device's MDM
/// profile, or the policy of the device's managing team.
public nonisolated enum ManagedSource: Sendable, Hashable {
    case device
    case team(String)
}

/// Values an administrator set for cmux, read from the managed preference
/// domain. Keys that start with a lowercase letter are cmux.json key paths
/// (`appearance.borders`); keys that start with an uppercase letter are
/// policy keys that are not user settings (`EnrollmentToken`,
/// `DisabledFeatures`, ...). Forced values override the user's file;
/// recommended values only replace the product default.
public nonisolated struct ManagedPreferences: Sendable, Equatable {
    public var forced: [String: JSONValue]
    public var recommended: [String: JSONValue]

    public init(forced: [String: JSONValue] = [:], recommended: [String: JSONValue] = [:]) {
        self.forced = forced
        self.recommended = recommended
    }

    public static let empty = ManagedPreferences()

    /// The managed preference domain every channel (stable, NIGHTLY, DEV)
    /// reads. Not a bundle id on purpose: the app never writes it, so a
    /// non-forced value there can only come from an administrator.
    public static let domain = "com.manaflow.cmux"
    /// The shipped updater's domain; only its forced `DisableAutoUpdate` is read.
    public static let legacyDomain = "com.cmuxterm.app"
    public static let legacyKeys = ["DisableAutoUpdate"]
    /// DEV and test builds read this plist instead of the domain.
    public static let fileOverrideKey = "CMUX_NEXT_MANAGED_PREFS_FILE"

    /// Policy keys that are not cmux.json settings (docs/mdm/managed-preferences.md).
    public static let policyKeys: [ManagedPolicyKey] = [
        ManagedPolicyKey("EnrollmentToken", type: .string,
                         help: "Team enrollment token from the cmux dashboard. Signed-in users in a verified domain of the team join it; the token alone never grants membership."),
        ManagedPolicyKey("ManagedTeam", type: .string, help: "Team id (team_...) that manages this device."),
        ManagedPolicyKey("RestrictToManagedTeam", type: .boolean, help: "Refuse sign-in to any team other than ManagedTeam on this device."),
        ManagedPolicyKey("DisabledFeatures", type: .stringArray(["computerUse", "browserAutomation", "mcp", "cloud", "apps", "remoteHosts"]),
                         help: "Features to turn off: their UI, actions and host operations are removed."),
        ManagedPolicyKey("UpdateChannel", type: .choice(["stable", "nightly"]), help: "Update channel this device follows."),
        ManagedPolicyKey("MinimumVersion", type: .string, help: "Oldest cmux version allowed to sign in, for example 1.2.0."),
        ManagedPolicyKey("AllowedSignInMethods", type: .stringArray(["sso", "password", "oauth"]), help: "Sign-in methods the app offers."),
        ManagedPolicyKey("DisableAutoUpdate", type: .boolean, help: "Turn off automatic updates (also honored in the legacy com.cmuxterm.app domain).")
    ]

    /// Whether `key` names a cmux.json setting (as opposed to a policy key).
    public static func isSettingKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first else { return false }
        return CharacterSet.lowercaseLetters.contains(first)
    }

    /// Converts a property list value (CFPreferences or a plist file) to JSON.
    /// Dates and data have no cmux.json form and are dropped.
    public static func json(fromPropertyList value: Any) -> JSONValue? {
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(array.compactMap { json(fromPropertyList: $0) })
        case let dictionary as [String: Any]:
            return .object(dictionary.compactMapValues { json(fromPropertyList: $0) })
        default:
            return nil
        }
    }
}

/// Reads the managed preferences. Implementations must be cheap enough to
/// call on every settings load and must not block on the network.
public protocol ManagedPreferenceReader: Sendable {
    func read() -> ManagedPreferences
}
