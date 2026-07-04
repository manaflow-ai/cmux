import CmuxMobileSupport
public import Foundation
public import Observation

/// Owns the Parakeet CoreML model location and download lifecycle.
@MainActor
@Observable
public final class ParakeetModelStore {
    /// The directory name FluidAudio uses for Parakeet v3.
    public static let modelDirectoryName = "parakeet-tdt-0.6b-v3"

    /// Current installation/download state.
    public private(set) var state: ParakeetDownloadState

    /// The directory passed to FluidAudio for model storage.
    public let modelDirectory: URL

    private let fileManager: FileManager
    private let downloader: any ParakeetModelDownloading
    private let installedDetector: @Sendable (URL) -> Bool
    private var downloadTask: Task<Void, Never>?
    private var downloadAttemptID = UUID()

    /// Creates a model store.
    /// - Parameters:
    ///   - applicationSupportDirectory: Optional application-support base. When
    ///     `nil`, the user's Application Support directory is used.
    ///   - fileManager: File manager used for disk operations.
    ///   - downloader: Downloader implementation. Tests pass a fake.
    public init(
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default,
        downloader: any ParakeetModelDownloading = FluidAudioParakeetModelDownloader(),
        installedDetector: @escaping @Sendable (URL) -> Bool = { FluidAudioParakeetModelDownloader.modelsExist(at: $0) }
    ) {
        self.fileManager = fileManager
        self.downloader = downloader
        self.installedDetector = installedDetector
        let baseDirectory = applicationSupportDirectory ?? Self.defaultApplicationSupportDirectory(fileManager: fileManager)
        self.modelDirectory = baseDirectory
            .appendingPathComponent("cmux-voice-models", isDirectory: true)
            .appendingPathComponent(Self.modelDirectoryName, isDirectory: true)
        self.state = installedDetector(modelDirectory) ? .installed : .idle
    }

    /// Whether the model currently exists on disk.
    public var isInstalled: Bool {
        installedDetector(modelDirectory)
    }

    /// Refreshes ``state`` from disk, useful after app relaunch or external deletion.
    public func refreshInstalledState() {
        guard !state.isDownloading else { return }
        state = isInstalled ? .installed : .idle
    }

    /// Starts downloading the model if no download is currently active.
    public func downloadModel() {
        guard !state.isDownloading else { return }
        let attemptID = UUID()
        downloadAttemptID = attemptID
        state = .downloading(ParakeetDownloadProgress(fractionCompleted: 0, phaseDescription: ""))
        downloadTask = Task { [weak self, attemptID] in
            guard let self else { return }
            do {
                try Self.prepareModelDirectory(self.modelDirectory, fileManager: self.fileManager)
                try await self.downloader.download(to: self.modelDirectory) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.downloadAttemptID == attemptID, self.state.isDownloading else { return }
                        self.state = .downloading(progress)
                    }
                }
                guard !Task.isCancelled else { throw CancellationError() }
                Self.excludeFromBackup(self.modelDirectory, fileManager: self.fileManager)
                guard self.downloadAttemptID == attemptID else { return }
                self.state = self.installedDetector(self.modelDirectory)
                    ? .installed
                    : .failed(L10n.string(
                        "mobile.voice.parakeet.missingAfterDownload",
                        defaultValue: "Model files were not found after download."
                    ))
            } catch {
                guard self.downloadAttemptID == attemptID else { return }
                if Self.isCancellation(error) {
                    self.state = self.installedDetector(self.modelDirectory) ? .installed : .idle
                } else {
                    self.state = .failed(error.localizedDescription)
                }
            }
            if self.downloadAttemptID == attemptID {
                self.downloadTask = nil
            }
        }
    }

    /// Cancels the active download, if any.
    public func cancelDownload() {
        downloadAttemptID = UUID()
        downloadTask?.cancel()
        downloadTask = nil
        if state.isDownloading {
            state = isInstalled ? .installed : .idle
        }
    }

    /// Deletes the local model directory and returns to idle.
    public func deleteModel() throws {
        cancelDownload()
        if fileManager.fileExists(atPath: modelDirectory.path) {
            try fileManager.removeItem(at: modelDirectory)
        }
        state = .idle
    }

    /// Returns whether FluidAudio can find the required Parakeet v3 files.
    /// - Parameter directory: The custom model directory root.
    /// - Returns: `true` when all required files are present.
    public nonisolated static func modelsExist(at directory: URL) -> Bool {
        FluidAudioParakeetModelDownloader.modelsExist(at: directory)
    }

    private static func defaultApplicationSupportDirectory(fileManager: FileManager) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    private static func prepareModelDirectory(_ directory: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        excludeFromBackup(directory, fileManager: fileManager)
        excludeFromBackup(directory.deletingLastPathComponent(), fileManager: fileManager)
    }

    private static func excludeFromBackup(_ directory: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return Task.isCancelled
    }
}
