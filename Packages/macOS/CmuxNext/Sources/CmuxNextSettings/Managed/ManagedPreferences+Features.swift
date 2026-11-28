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

extension ManagedPreferences {
    /// What lockdown mode (`sessions.lockdown`, RFD 0211) turns off in the app: Cloud and computer use.
    /// Its agent and model allowlists are acpmux's (`ChatSettings.lockdown`).
    public static let lockdownFeatures: Set<ActionFeature> = [.cloud, .computerUse]

    /// Whether lockdown mode is on in `root` (the effective settings).
    public static func lockdownOn(_ root: JSONValue) -> Bool {
        root.value(at: SessionSettings.lockdownPath)?.boolValue ?? SessionSettings.lockdownDefault
    }

    /// The features `DisabledFeatures` turns off, plus ``lockdownFeatures`` when lockdown mode is on.
    public static func disabledFeatures(in policy: [String: JSONValue], root: JSONValue)
        -> (features: Set<ActionFeature>, problem: SettingsDiagnostic?) {
        var result = disabledFeatures(in: policy)
        if lockdownOn(root) { result.features.formUnion(lockdownFeatures) }
        return result
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
        let forced = managedReader.read().forced
        var features = ManagedPreferences.disabledFeatures(in: forced).features
        // A profile forcing lockdown on turns Cloud and computer use off before they start too.
        if forced[SessionSettings.lockdownPath.joined(separator: ".")]?.boolValue == true {
            features.formUnion(ManagedPreferences.lockdownFeatures)
        }
        applier.registry.disabledFeatures = features
    }
}
