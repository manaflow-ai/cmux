import Foundation

@_spi(CmuxHostTransport)
public enum CmuxExtensionValidationError: Error, Equatable, Sendable {
    case unsupportedAPIVersion(requested: CmuxExtensionAPIVersion, supported: CmuxExtensionAPIVersion)
    case emptyIdentifier
    case emptyDisplayName
    case payloadTooLarge(kind: String, actualBytes: Int, maximumBytes: Int)
}
