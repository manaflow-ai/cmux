import Foundation

/// Validates a sidebar extension manifest before CMUX trusts it.
@_spi(CmuxHostTransport)
public func validateSidebarManifest(
    _ manifest: CmuxExtensionManifest,
    supportedAPIVersion: CmuxExtensionAPIVersion = .sidebarV2
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
}
