public import Foundation

/// A validated on-disk OWL Chromium runtime installation.
///
/// A runtime directory is one extracted release archive from
/// `manaflow-ai/chromium`, containing `Content Shell.app`, its helper apps,
/// and `libowl_fresh_mojo_runtime.dylib`. Use ``ChromiumRuntimeLocator`` to
/// find and validate one.
public struct ChromiumRuntimeBundle: Sendable, Equatable {
    /// File name of the embeddable runtime dylib inside a runtime directory.
    public static let libraryFileName = "libowl_fresh_mojo_runtime.dylib"
    /// Relative path of the Content Shell executable inside a runtime directory.
    public static let contentShellExecutablePath = "Content Shell.app/Contents/MacOS/Content Shell"
    /// File name of the build-metadata manifest inside a runtime directory.
    public static let manifestFileName = "owl-runtime-manifest.json"

    /// Root directory of the extracted runtime archive.
    public let rootDirectory: URL
    /// Absolute path of `libowl_fresh_mojo_runtime.dylib`.
    public let libraryURL: URL
    /// Absolute path of the Content Shell browser executable launched per session.
    public let contentShellExecutableURL: URL
    /// Build metadata, when `owl-runtime-manifest.json` was present and valid.
    public let manifest: ChromiumRuntimeManifest?

    /// Creates a bundle from already-validated paths.
    ///
    /// Prefer ``ChromiumRuntimeLocator/bundle(at:)`` which validates the
    /// directory layout before constructing this value.
    public init(
        rootDirectory: URL,
        libraryURL: URL,
        contentShellExecutableURL: URL,
        manifest: ChromiumRuntimeManifest?
    ) {
        self.rootDirectory = rootDirectory
        self.libraryURL = libraryURL
        self.contentShellExecutableURL = contentShellExecutableURL
        self.manifest = manifest
    }
}
