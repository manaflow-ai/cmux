public import CmuxNextActions

extension ManagedPreferences {
    /// The features `DisabledFeatures` turns off, from the effective policy
    /// (forced values only), with a diagnostic for a value it cannot fully
    /// read. A malformed value (not an array of strings) turns every feature
    /// off: the administrator meant to restrict, so a typo must not leave
    /// everything on. An unknown name is reported and ignored; the names it
    /// can read still apply. A problem never turns a feature on.
    public static func disabledFeatures(in policy: [String: JSONValue]) -> (features: Set<ActionFeature>, problem: SettingsDiagnostic?) {
        guard let value = policy["DisabledFeatures"] else { return ([], nil) }
        guard case .array(let items) = value, items.allSatisfy({ $0.stringValue != nil }) else {
            return (Set(ActionFeature.allCases), SettingsDiagnostic(
                kind: .invalidValue, path: "DisabledFeatures",
                message: "DisabledFeatures must be an array of feature names; every feature is turned off until it is fixed"))
        }
        let names = items.compactMap(\.stringValue)
        let unknown = names.filter { ActionFeature(rawValue: $0) == nil }
        let features = Set(names.compactMap(ActionFeature.init(rawValue:)))
        guard !unknown.isEmpty else { return (features, nil) }
        let known = ActionFeature.allCases.map(\.rawValue).joined(separator: ", ")
        return (features, SettingsDiagnostic(
            kind: .invalidValue, path: "DisabledFeatures",
            message: "DisabledFeatures names unknown features \(unknown.joined(separator: ", ")) (known: \(known))"))
    }
}

extension SettingsController {
    /// Applies `DisabledFeatures` from a synchronous read of the forced
    /// managed values, before Cloud, SSH and apps start, so no feature runs
    /// in the window before the first full settings load.
    /// The forced managed values, read synchronously (launch only: later
    /// changes arrive through ``managedPolicy``).
    public func forcedManagedValuesNow() -> [String: JSONValue] { managedReader.read().forced }

    public func applyManagedFeaturesNow() {
        applier.registry.disabledFeatures = ManagedPreferences.disabledFeatures(in: managedReader.read().forced).features
    }
}
