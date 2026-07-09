@_spi(CmuxHostTransport) import CmuxExtensionKit

extension CMUXSidebarExtensionEffectiveGrant {
    /// A deterministic identity for the "kept limited access" choice the user
    /// made for this grant, used as the key in
    /// ``CMUXSidebarExtensionLimitedChoiceStore``.
    ///
    /// Built purely from the extension's `bundleIdentifier`, its manifest id,
    /// the manifest's minimum API version, and the sorted raw values of the
    /// requested read and action scopes, so the same extension at the same
    /// requested-scope shape always maps to the same key.
    public func limitedChoiceKey(bundleIdentifier: String) -> String {
        let readScopes = manifest.readScopes.map(\.rawValue).sorted().joined(separator: ",")
        let actionScopes = manifest.actionScopes.map(\.rawValue).sorted().joined(separator: ",")
        return "\(bundleIdentifier)|\(manifest.id)|\(manifest.minimumAPIVersion.major).\(manifest.minimumAPIVersion.minor)|\(readScopes)|\(actionScopes)"
    }
}
