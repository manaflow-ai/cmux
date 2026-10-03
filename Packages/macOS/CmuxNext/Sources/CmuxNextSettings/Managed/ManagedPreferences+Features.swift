public import CmuxNextActions

extension ManagedPreferences {
    /// The features `DisabledFeatures` turns off, from the effective policy
    /// (forced values only). Names the app does not know are ignored; the
    /// MDM schema lists the known ones.
    public static func disabledFeatures(in policy: [String: JSONValue]) -> Set<ActionFeature> {
        guard case .array(let items)? = policy["DisabledFeatures"] else { return [] }
        return Set(items.compactMap { $0.stringValue.flatMap(ActionFeature.init(rawValue:)) })
    }
}
