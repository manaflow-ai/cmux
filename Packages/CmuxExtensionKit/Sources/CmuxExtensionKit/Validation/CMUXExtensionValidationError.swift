import Foundation

public enum CMUXExtensionValidationError: Error, Equatable, Sendable {
    case unsupportedKind(CMUXExtensionKind)
    case unsupportedAPIVersion(requested: CMUXExtensionAPIVersion, supported: CMUXExtensionAPIVersion)
    case emptyIdentifier
    case emptyDisplayName
    case payloadTooLarge(kind: String, actualBytes: Int, maximumBytes: Int)
}
