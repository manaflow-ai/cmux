import CmuxMobileSupport
public import Foundation
public import Observation
import OSLog

private let parakeetModelStoreLog = Logger(subsystem: "dev.cmux.ios", category: "parakeet-model-store")

/// Prefix for renamed-aside model directories awaiting background removal.
private let parakeetPendingDeletePrefix = ".pending-delete-"

/// Owns the Parakeet CoreML model location and download lifecycle.
@MainActor
@Observable
public final class ParakeetModelStore {
    /// The directory name FluidAudio uses for Parakeet v3.
    public static let modelDirectoryName = ParakeetModelDescriptor.parakeetV3Int8.folderName

    /// Current installation/download state.
    public private(set) var state: ParakeetDownloadState

    /// The directory passed to FluidAudio for model storage.
    public let modelDirectory: URL
    /// Engine this store downloads and detects.
    public let engineID: VoiceEngineID

    private let fileManager: FileManager
    private let downloader: any ParakeetModelDownloading
    private let installedDetector: @Sendable (URL) -> Bool
    let descriptor: ParakeetModelDescriptor
    private var downloadTask: Task<Void, Never>?
    private var downloadAttemptID = UUID()

    /// Creates a model store.
    /// - Parameters:
    ///   - applicationSupportDirectory: Optional application-support base. When
    ///     `nil`, the user's Application Support directory is used.
    ///   - fileManager: File manager used for disk operations.
    ///   - downloader: Downloader implementation. Tests pass a fake.
    public init(
        descriptor: ParakeetModelDescriptor = .parakeetV3Int8,
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default,
        downloader: any ParakeetModelDownloading = FluidAudioParakeetModelDownloader(),
        installedDetector: (@Sendable (URL) -> Bool)? = nil
    ) {
        self.fileManager = fileManager
        self.downloader = downloader
        self.descriptor = descriptor
        self.engineID = descriptor.engineID
        self.installedDetector = installedDetector ?? { directory in
            FluidAudioParakeetModelDownloader.modelsExist(at: directory, descriptor: descriptor)
        }
        let baseDirectory = applicationSupportDirectory ?? Self.defaultApplicationSupportDirectory(fileManager: fileManager)
        self.modelDirectory = baseDirectory
            .appendingPathComponent("cmux-voice-models", isDirectory: true)
            .appendingPathComponent(descriptor.folderName, isDirectory: true)
        self.state = self.installedDetector(modelDirectory) ? .installed : .idle
        sweepPendingDeletes(in: modelDirectory.deletingLastPathComponent())
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
                try await self.downloader.download(self.descriptor, to: self.modelDirectory) { [weak self] progress in
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
                    // The raw error string exposes internal domains/codes
                    // (NSURLErrorDomain, CoreML compile failures) in the settings
                    // UI; log the detail and show cmux-domain copy instead.
                    parakeetModelStoreLog.error("Parakeet model download failed: \(error.localizedDescription, privacy: .public)")
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

    /// Deletes the local model directory and returns to idle.
    ///
    /// The store is `@MainActor` and the compiled model tree is about 483 MB, so a
    /// synchronous `removeItem` here would block the settings UI. Instead the
    /// directory is atomically renamed aside (an O(1) same-volume rename, so
    /// `isInstalled` flips immediately and a failure still throws), and the
    /// actual byte removal runs on a detached utility task. Orphaned rename
    /// targets from a mid-delete crash are swept by `sweepPendingDeletes()`.
    public func deleteModel(preservingSharedFiles: Bool = false) throws {
        cancelDownload()
        guard fileManager.fileExists(atPath: modelDirectory.path) else {
            state = .idle
            return
        }

        if preservingSharedFiles {
            let pendingDeletes = try moveModelSpecificItemsAside()
            try Self.removeDirectoryIfEmpty(modelDirectory, fileManager: fileManager)
            if !pendingDeletes.isEmpty {
                // The byte removal deliberately uses FileManager.default instead of
                // capturing the injected instance: FileManager is not Sendable, and
                // remote/CI toolchains reject any capture in this sending closure.
                // Both operate on the same real filesystem path.
                Task.detached(priority: .utility) {
                    for pendingDelete in pendingDeletes {
                        try? FileManager.default.removeItem(at: pendingDelete)
                    }
                }
            }
        } else {
            if let pendingDelete = try moveModelDirectoryAside() {
                // The byte removal deliberately uses FileManager.default instead of
                // capturing the injected instance: FileManager is not Sendable, and
                // remote/CI toolchains reject any capture in this sending closure.
                // Both operate on the same real filesystem path.
                Task.detached(priority: .utility) {
                    try? FileManager.default.removeItem(at: pendingDelete)
                }
            }
        }
        state = .idle
    }


    /// Removes leftover pending-delete directories (from a launch that died
    /// between the rename and the background removal). Runs off the main actor.
    private nonisolated func sweepPendingDeletes(in baseDirectory: URL) {
        // Uses FileManager.default instead of the injected instance: FileManager
        // is not Sendable, and remote/CI toolchains reject any capture in this
        // sending closure. Both operate on the same real filesystem path.
        Task.detached(priority: .utility) {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: baseDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            ) else { return }
            for entry in entries where entry.lastPathComponent.hasPrefix(parakeetPendingDeletePrefix) {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    /// Returns whether FluidAudio can find the required Parakeet v3 files.
    /// - Parameter directory: The custom model directory root.
    /// - Returns: `true` when all required files are present.
    public nonisolated static func modelsExist(at directory: URL) -> Bool {
        FluidAudioParakeetModelDownloader.modelsExist(at: directory)
    }

    /// Returns whether FluidAudio can find the descriptor's required files.
    public nonisolated static func modelsExist(at directory: URL, descriptor: ParakeetModelDescriptor) -> Bool {
        FluidAudioParakeetModelDownloader.modelsExist(at: directory, descriptor: descriptor)
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

    private func moveModelDirectoryAside() throws -> URL? {
        guard fileManager.fileExists(atPath: modelDirectory.path) else { return nil }
        let pending = modelDirectory.deletingLastPathComponent()
            .appendingPathComponent("\(parakeetPendingDeletePrefix)\(UUID().uuidString)-\(modelDirectory.lastPathComponent)", isDirectory: true)
        try fileManager.moveItem(at: modelDirectory, to: pending)
        return pending
    }

    private func moveModelSpecificItemsAside() throws -> [URL] {
        var pendingDeletes: [URL] = []
        for name in descriptor.modelSpecificTopLevelNames {
            let source = modelDirectory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let pending = modelDirectory.deletingLastPathComponent()
                .appendingPathComponent("\(parakeetPendingDeletePrefix)\(UUID().uuidString)-\(name)", isDirectory: true)
            try fileManager.moveItem(at: source, to: pending)
            pendingDeletes.append(pending)
        }
        return pendingDeletes
    }

    private static func removeDirectoryIfEmpty(_ directory: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        if contents.isEmpty {
            try fileManager.removeItem(at: directory)
        }
    }
}
