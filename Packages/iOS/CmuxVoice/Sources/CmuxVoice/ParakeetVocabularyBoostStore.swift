import CmuxMobileSupport
import FluidAudio
public import Foundation
public import Observation
import OSLog

private let parakeetVocabularyBoostStoreLog = Logger(subsystem: "dev.cmux.ios", category: "parakeet-vocabulary-boost")
private let parakeetVocabularyBoostPendingDeletePrefix = ".pending-delete-vocabulary-boost-"

/// Owns the optional CTC add-on used for Parakeet vocabulary boosting.
@MainActor
@Observable
public final class ParakeetVocabularyBoostStore {
    /// Current installation/download state.
    public private(set) var state: ParakeetDownloadState

    /// Directory FluidAudio's vocabulary rescorer expects for CTC assets.
    public let modelDirectory: URL

    private let descriptor: ParakeetVocabularyBoostDescriptor
    private let fileManager: FileManager
    private let downloader: any ParakeetVocabularyBoostDownloading
    private let installedDetector: @Sendable (URL) -> Bool
    private var downloadTask: Task<Void, Never>?
    private var downloadAttemptID = UUID()

    /// Creates a vocabulary-boost add-on store.
    /// - Parameters:
    ///   - descriptor: Add-on descriptor to manage.
    ///   - modelDirectory: Optional exact cache directory. Production uses
    ///     FluidAudio's default CTC directory because the SDK's tokenizer lookup
    ///     resolves there even when CTC models are loaded from a custom path.
    ///   - fileManager: File manager used for disk operations.
    ///   - downloader: Downloader implementation. Tests pass a fake.
    ///   - installedDetector: Optional detector used by tests to avoid filesystem setup.
    public init(
        descriptor: ParakeetVocabularyBoostDescriptor = .ctc110m,
        modelDirectory: URL? = nil,
        fileManager: FileManager = .default,
        downloader: any ParakeetVocabularyBoostDownloading = FluidAudioParakeetModelDownloader(),
        installedDetector: (@Sendable (URL) -> Bool)? = nil
    ) {
        self.descriptor = descriptor
        self.fileManager = fileManager
        self.downloader = downloader
        self.modelDirectory = modelDirectory ?? CtcModels.defaultCacheDirectory(for: .ctc110m)
        self.installedDetector = installedDetector ?? { directory in
            FluidAudioParakeetModelDownloader.vocabularyBoostModelsExist(at: directory, descriptor: descriptor)
        }
        self.state = self.installedDetector(self.modelDirectory) ? .installed : .idle
        sweepPendingDeletes(in: self.modelDirectory.deletingLastPathComponent())
    }

    /// Whether the add-on currently exists on disk.
    public var isInstalled: Bool {
        installedDetector(modelDirectory)
    }

    /// Directory to pass into recognition only when the add-on is installed.
    public var installedDirectoryForRecognition: URL? {
        isInstalled ? modelDirectory : nil
    }

    /// Refreshes ``state`` from disk.
    public func refreshInstalledState() {
        guard !state.isDownloading else { return }
        state = isInstalled ? .installed : .idle
    }

    /// Starts downloading the add-on if no download is currently active.
    public func downloadModel() {
        guard !state.isDownloading else { return }
        let attemptID = UUID()
        downloadAttemptID = attemptID
        state = .downloading(ParakeetDownloadProgress(fractionCompleted: 0, phaseDescription: ""))
        downloadTask = Task { [weak self, attemptID] in
            guard let self else { return }
            do {
                try Self.prepareDirectory(self.modelDirectory, fileManager: self.fileManager)
                try await self.downloader.downloadVocabularyBoost(self.descriptor, to: self.modelDirectory) { [weak self] progress in
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
                    parakeetVocabularyBoostStoreLog.error("Parakeet vocabulary boost download failed: \(error.localizedDescription, privacy: .public)")
                    self.state = .failed(L10n.string(
                        "mobile.voice.parakeet.downloadFailed",
                        defaultValue: "Couldn't download the voice model. Check your connection and try again."
                    ))
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

    /// Deletes the add-on directory and returns to idle.
    public func deleteModel() throws {
        cancelDownload()
        guard fileManager.fileExists(atPath: modelDirectory.path) else {
            state = .idle
            return
        }
        if let pendingDelete = try moveDirectoryAside() {
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: pendingDelete)
            }
        }
        state = .idle
    }

    /// Returns whether all vocabulary-boost files exist.
    public nonisolated static func modelsExist(at directory: URL) -> Bool {
        FluidAudioParakeetModelDownloader.vocabularyBoostModelsExist(at: directory)
    }

    private static func prepareDirectory(_ directory: URL, fileManager: FileManager) throws {
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

    private func moveDirectoryAside() throws -> URL? {
        guard fileManager.fileExists(atPath: modelDirectory.path) else { return nil }
        let pending = modelDirectory.deletingLastPathComponent()
            .appendingPathComponent("\(parakeetVocabularyBoostPendingDeletePrefix)\(UUID().uuidString)-\(modelDirectory.lastPathComponent)", isDirectory: true)
        try fileManager.moveItem(at: modelDirectory, to: pending)
        return pending
    }

    private nonisolated func sweepPendingDeletes(in baseDirectory: URL) {
        Task.detached(priority: .utility) {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: baseDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            ) else { return }
            for entry in entries where entry.lastPathComponent.hasPrefix(parakeetVocabularyBoostPendingDeletePrefix) {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }
}
