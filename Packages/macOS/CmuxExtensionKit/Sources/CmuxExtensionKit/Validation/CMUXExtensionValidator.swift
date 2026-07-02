import Foundation

/// Validates a sidebar extension manifest before CMUX trusts it.
@_spi(CmuxHostTransport)
public func validateSidebarManifest(
    _ manifest: CmuxExtensionManifest,
    supportedAPIVersion: CmuxExtensionAPIVersion = .sidebarV2_1
) throws {
    guard manifest.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        throw CmuxExtensionValidationError.emptyIdentifier
    }
    guard manifest.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        throw CmuxExtensionValidationError.emptyDisplayName
    }
    guard manifest.minimumAPIVersion.major == supportedAPIVersion.major,
          manifest.minimumAPIVersion <= supportedAPIVersion else {
        throw CmuxExtensionValidationError.unsupportedAPIVersion(
            requested: manifest.minimumAPIVersion,
            supported: supportedAPIVersion
        )
    }
    // Each requested action scope may need a newer contract than the 2.0 baseline.
    // Require the manifest to declare at least that version so an older host — which
    // advertises a lower `supportedAPIVersion` and drops scopes it cannot decode —
    // rejects the extension by version above rather than silently running it with a
    // capability trimmed away.
    for scope in manifest.actionScopes {
        let required = scope.minimumAPIVersion
        guard manifest.minimumAPIVersion >= required else {
            throw CmuxExtensionValidationError.actionScopeRequiresNewerAPIVersion(
                scope: scope,
                required: required,
                declared: manifest.minimumAPIVersion
            )
        }
    }
}
