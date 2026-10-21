public import Foundation

/// Fetches a pack into a file, resuming a partial one.
///
/// ``URLSessionChromiumRuntimeDownloader`` is the app's; tests pass a fake that
/// writes bytes from memory.
public protocol ChromiumRuntimeDownloading: Sendable {
    /// Downloads `url` into `file`. When `file` already holds bytes the
    /// download continues after them (`Range`); a server that answers with
    /// the whole body (200) makes the file start again.
    ///
    /// - Parameters:
    ///   - url: The pack URL.
    ///   - file: The partial file (created when missing).
    ///   - expectedSize: The pinned size; a file already this size is not fetched.
    ///   - progress: Called with the bytes on disk as they grow.
    /// - Throws: ``ChromiumRuntimeInstallError/http(_:)`` or ``ChromiumRuntimeInstallError/transfer(_:)``.
    func download(_ url: URL, to file: URL, expectedSize: Int64,
                  progress: @escaping @Sendable (Int64) -> Void) async throws(ChromiumRuntimeInstallError)
}
