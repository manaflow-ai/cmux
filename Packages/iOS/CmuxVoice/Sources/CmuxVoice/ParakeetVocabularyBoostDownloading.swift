public import Foundation

/// Downloads the optional Parakeet CTC vocabulary-boost add-on.
public protocol ParakeetVocabularyBoostDownloading: Sendable {
    /// Downloads the add-on to `directory`, reporting progress snapshots.
    /// - Parameters:
    ///   - descriptor: Add-on descriptor to download.
    ///   - directory: The exact FluidAudio default cache directory.
    ///   - progress: Receives progress callbacks from the downloader.
    func downloadVocabularyBoost(
        _ descriptor: ParakeetVocabularyBoostDescriptor,
        to directory: URL,
        progress: @escaping @Sendable (ParakeetDownloadProgress) -> Void
    ) async throws
}
