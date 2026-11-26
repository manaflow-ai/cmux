public import Foundation

/// Downloads a file to a local path.
public protocol AppChannelDownloading: Sendable {
    /// Downloads `url` to `destination`, reporting the completed fraction when the server
    /// sends a length (`nil` otherwise). Honors task cancellation.
    func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws
}

/// Attaches and detaches disk images.
public protocol DiskImageMounting: Sendable {
    /// Attaches `image` read-only without showing it in Finder and returns its mount point.
    func attach(_ image: URL) async throws -> URL
    /// Detaches the volume at `mountPoint`. Best effort; never throws.
    func detach(_ mountPoint: URL) async
}

/// Opens an app bundle.
public protocol AppLaunching: Sendable {
    /// Opens the app at `appURL`, or activates it when it is already running.
    func openApplication(at appURL: URL) async throws
}

/// The file-system operations an install needs.
public protocol AppInstallFileSystem: Sendable {
    /// Whether an item exists at `url`.
    func fileExists(at url: URL) -> Bool
    /// Whether the current user can create items in `directory`.
    func isWritableDirectory(_ directory: URL) -> Bool
    /// Creates `directory` and any missing parents.
    func createDirectory(at directory: URL) throws
    /// Copies the item at `source` to `destination`, which must not exist.
    func copyItem(at source: URL, to destination: URL) throws
    /// Moves the item at `source` to `destination`, which must not exist.
    func moveItem(at source: URL, to destination: URL) throws
    /// Atomically replaces the item at `original` with the one at `replacement`.
    func replaceItem(at original: URL, with replacement: URL) throws
    /// Removes the item at `url` if it exists.
    func removeItem(at url: URL)
    /// Top-level entries of `directory`.
    func contentsOfDirectory(at directory: URL) -> [URL]
    /// `CFBundleIdentifier` of the bundle at `appURL`.
    func bundleIdentifier(ofAppAt appURL: URL) -> String?
}
