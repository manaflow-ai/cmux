import Foundation

public enum CMUXExtensionValidationError: Error, Equatable, Sendable {
    case unsupportedKind(CMUXExtensionKind)
    case unsupportedAPIVersion(requested: CMUXExtensionAPIVersion, supported: CMUXExtensionAPIVersion)
    case emptyIdentifier
    case emptyDisplayName
}

public enum CMUXExtensionValidator {
    public static func validateSidebarManifest(
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
}
