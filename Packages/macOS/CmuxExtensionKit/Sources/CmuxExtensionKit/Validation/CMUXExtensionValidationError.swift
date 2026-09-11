import Foundation

/// Fail-closed validation failures emitted before an extension is trusted.
@_spi(CmuxHostTransport)
public enum CmuxExtensionValidationError: Error, Equatable, Sendable {
    /// A sidebar manifest requires a different or newer sidebar API.
    case unsupportedAPIVersion(requested: CmuxExtensionAPIVersion, supported: CmuxExtensionAPIVersion)
    /// The manifest identifier is blank.
    case emptyIdentifier
    /// The user-visible display name is blank.
    case emptyDisplayName
    /// A transport payload exceeds its declared byte limit.
    case payloadTooLarge(kind: String, actualBytes: Int, maximumBytes: Int)
    /// The identifier contains a path separator or an unsupported character.
    case invalidIdentifier(String)
    /// Two declarations in one manifest use the same identifier.
    case duplicateDeclaration(kind: String, identifier: String)
    /// A declaration is syntactically valid JSON but cannot be represented by
    /// the current plugin protocol.
    case invalidDeclaration(kind: String, identifier: String, reason: String)
    /// The plugin manifest asks for an incompatible process-backed API.
    case unsupportedPluginAPIVersion(requested: CmuxExtensionAPIVersion, supported: CmuxExtensionAPIVersion)
    /// A plugin executable must stay inside its plugin directory.
    case invalidEntrypoint(String)
    /// A manifest's id must match the directory that contains it.
    case directoryIdentifierMismatch(expected: String, actual: String)
    /// A plugin directory did not contain a manifest file.
    case missingManifest
    /// Two plugin directories declared the same id.
    case duplicatePluginIdentifier(String)
    /// A manifest file could not be decoded into the manifest schema.
    case malformedManifest(String)
    /// The current host has not implemented a requested plugin surface yet.
    case unsupportedPluginScope(CmuxExtensionPluginScope)
    /// A process-backed plugin must provide a child executable.
    case missingEntrypointDeclaration
}
