/// The managed device keys the App hands to their owners (`ManagedPolicyBridge`): `UpdateChannel` and
/// `MinimumVersion` to the updater (P17-2), `ManagedTeam` to Cloud auth while `RestrictToManagedTeam` is on
/// (P17-3). Pure: read from a managed policy (forced values only, ``SettingsController/managedPolicyInEffect``),
/// so a policy change of other keys compares equal and applies nothing.
public nonisolated struct ManagedDeviceValues: Equatable, Sendable {
    public let channel: String?
    public let minimumVersion: String?
    /// `ManagedTeam` while `RestrictToManagedTeam` is on.
    public let team: String?

    public init(_ policy: [String: JSONValue]) {
        channel = policy["UpdateChannel"]?.stringValue
        minimumVersion = policy["MinimumVersion"]?.stringValue
        team = policy["RestrictToManagedTeam"]?.boolValue == true ? policy["ManagedTeam"]?.stringValue : nil
    }
}

/// The organization's URL filters, Chrome's `URLBlocklist` and `URLAllowlist` policies in Chrome's filter format
/// (support.google.com/chrome/a/answer/9942583), from a managed policy (forced values only). The browser turns
/// them into its `BrowserURLFilter`; a value that is not a list of strings is no filter.
public nonisolated struct ManagedURLFilters: Hashable, Sendable {
    public let blocklist: [String]
    public let allowlist: [String]

    public init(_ policy: [String: JSONValue]) {
        func strings(_ key: String) -> [String] {
            guard case .array(let items) = policy[key] else { return [] }
            return items.compactMap(\.stringValue)
        }
        blocklist = strings("URLBlocklist")
        allowlist = strings("URLAllowlist")
    }
}
