public import Foundation

/// Filesystem side of `cmux plugin install|link|remove`.
///
/// Cloning and building run in the CLI; this type owns staging, validation,
/// and the final move so the rules are testable without git. Nothing here
/// enables a plugin: that is always a separate, explicit step.
public struct CmuxPluginInstaller {
    public let paths: CmuxPluginPaths
    private let fileManager: FileManager

    public init(paths: CmuxPluginPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    /// A fresh hidden directory under the install root for one clone. The
    /// catalog skips hidden entries, so a crashed install is never loaded.
    public func makeStagingDirectory() throws -> URL {
        let staging = paths.installRoot.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    /// Reads the manifest of a candidate directory and checks it can be
    /// installed as an app extension plugin on this Mac.
    public func inspect(_ directory: URL) throws -> (manifest: CmuxPluginManifest, fingerprint: String) {
        let result = try CmuxPluginCatalog.readManifest(in: directory)
        guard result.manifest.kind == .extension else {
            throw CmuxPluginManifestError(
                "kind '\(result.manifest.kind.rawValue)' plugins are managed by cmux-tui (`\(result.manifest.kind.rawValue) plugin install`)"
            )
        }
        guard result.manifest.supportsMacOS else {
            throw CmuxPluginManifestError("plugin.platforms does not include macos")
        }
        return result
    }

    /// Moves a validated plugin directory into `installRoot/<name>`.
    public func commit(_ directory: URL, name: String, replacing: Bool) throws -> URL {
        let destination = paths.installDirectory(for: name)
        try prepareDestination(destination, replacing: replacing)
        try fileManager.moveItem(at: directory, to: destination)
        return destination
    }

    /// Symlinks a local development directory as `installRoot/<name>`.
    public func link(_ directory: URL, replacing: Bool) throws -> (name: String, destination: URL) {
        let source = directory.standardizedFileURL.resolvingSymlinksInPath()
        let (manifest, _) = try inspect(source)
        let destination = paths.installDirectory(for: manifest.name)
        try fileManager.createDirectory(at: paths.installRoot, withIntermediateDirectories: true)
        try prepareDestination(destination, replacing: replacing)
        try fileManager.createSymbolicLink(at: destination, withDestinationURL: source)
        return (manifest.name, destination)
    }

    /// Removes the install entry (only the symlink for a linked plugin) and
    /// its enablement. State and config directories are left for the user.
    public func remove(_ name: String) throws {
        try CmuxPluginManifest.validateName(name, label: "plugin name")
        let destination = paths.installDirectory(for: name)
        guard entryExists(destination) else {
            throw CmuxPluginManifestError("plugin '\(name)' is not installed")
        }
        try CmuxPluginEnablementStore(fileURL: paths.enablementFile).disable(name)
        try fileManager.removeItem(at: destination)
    }

    private func prepareDestination(_ destination: URL, replacing: Bool) throws {
        guard entryExists(destination) else { return }
        guard replacing else {
            throw CmuxPluginManifestError(
                "plugin '\(destination.lastPathComponent)' is already installed; pass --force to replace it"
            )
        }
        try fileManager.removeItem(at: destination)
    }

    /// True for a directory, file, or symlink (even a dangling one).
    private func entryExists(_ url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }
}
