import Foundation

/// State of the local Parakeet model installation.
public enum ParakeetDownloadState: Equatable, Sendable {
    /// No model is installed and no download is active.
    case idle
    /// The model is downloading or compiling.
    case downloading(ParakeetDownloadProgress)
    /// Required model files are present on disk.
    case installed
    /// The most recent download failed.
    case failed(String)

    /// Whether this state represents an active download task.
    public var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}
