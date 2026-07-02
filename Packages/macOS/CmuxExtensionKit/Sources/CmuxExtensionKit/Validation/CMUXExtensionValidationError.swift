import Foundation

@_spi(CmuxHostTransport)
public enum CmuxExtensionValidationError: Error, Equatable, Sendable {
    case unsupportedAPIVersion(requested: CmuxExtensionAPIVersion, supported: CmuxExtensionAPIVersion)
    /// A declared action scope requires a newer API version than the manifest advertises.
    case actionScopeRequiresNewerAPIVersion(
        scope: CmuxExtensionActionScope,
        required: CmuxExtensionAPIVersion,
        declared: CmuxExtensionAPIVersion
    )
    case emptyIdentifier
    case emptyDisplayName
    case payloadTooLarge(kind: String, actualBytes: Int, maximumBytes: Int)
}
