import Foundation

/// Reads and validates a `cmux-extension.json` from an extension directory.
public struct DockExtensionManifestLoader: Sendable {
    /// Creates a loader.
    public init() {}

    /// The manifest location inside an extension directory.
    public func manifestURL(inDirectory directory: URL) -> URL {
        directory.appendingPathComponent(DockExtensionManifest.manifestFileName, isDirectory: false)
    }

    /// Loads and parses the manifest at `directory`.
    ///
    /// - Throws: ``DockExtensionError/manifestNotFound(path:)`` when the file
    ///   is missing or unreadable; parse/validation errors from
    ///   ``DockExtensionManifest/parse(data:)``.
    public func load(fromDirectory directory: URL) throws -> DockExtensionManifest {
        let url = manifestURL(inDirectory: directory)
        // Enforce the size cap before reading: a linked directory or staged
        // checkout can put an arbitrarily large file at the manifest path, and
        // the guard inside `parse` would only run after allocating all of it.
        if let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           fileSize > DockExtensionManifest.maximumFileSize {
            throw DockExtensionError.manifestTooLarge(limitBytes: DockExtensionManifest.maximumFileSize)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DockExtensionError.manifestNotFound(path: url.path)
        }
        return try DockExtensionManifest.parse(data: data)
    }
}
