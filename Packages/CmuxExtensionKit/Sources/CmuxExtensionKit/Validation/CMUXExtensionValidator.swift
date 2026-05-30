import Foundation

/// Validates a sidebar extension manifest before CMUX trusts it.
public func validateSidebarManifest(
    _ manifest: CMUXExtensionManifest,
    supportedAPIVersion: CMUXExtensionAPIVersion = .sidebarV1
) throws {
    guard manifest.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        throw CMUXExtensionValidationError.emptyIdentifier
    }
    guard manifest.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        throw CMUXExtensionValidationError.emptyDisplayName
    }
    guard manifest.kind == .sidebar else {
        throw CMUXExtensionValidationError.unsupportedKind(manifest.kind)
    }
    guard manifest.minimumAPIVersion <= supportedAPIVersion else {
        throw CMUXExtensionValidationError.unsupportedAPIVersion(
            requested: manifest.minimumAPIVersion,
            supported: supportedAPIVersion
        )
    }
}
