public import Foundation

/// Downloads and loads the Parakeet model into a caller-owned directory.
public protocol ParakeetModelDownloading: Sendable {
    /// Download the model to `directory`, reporting progress snapshots as they arrive.
    /// - Parameters:
    ///   - directory: The custom model directory root.
    ///   - progress: Receives progress callbacks from the downloader.
    func download(
        to directory: URL,
        progress: @escaping @Sendable (ParakeetDownloadProgress) -> Void
    ) async throws
}
