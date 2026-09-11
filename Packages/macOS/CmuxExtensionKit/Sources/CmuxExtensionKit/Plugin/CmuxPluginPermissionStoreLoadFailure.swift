/// A failure to load an existing plugin permission grant file.
public enum CmuxPluginPermissionStoreLoadFailure: Error, Equatable, Sendable {
    /// The existing grant file could not be read.
    case unreadableFile
    /// The existing grant file was not valid grant JSON.
    case malformedFile
    /// The existing grant file uses a schema this host cannot safely rewrite.
    case unsupportedSchemaVersion(Int)
}
