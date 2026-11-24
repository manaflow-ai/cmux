import CmuxNextCompat
public import Foundation
import FluidAudio
import os

/// The Parakeet speech model on this Mac: downloads it once into cmux's own
/// folder, loads it, and reports where that stands (docs/design/voice-byo-providers.md
/// slice 3: "a model download state (progress, cancel, disk use shown), offline
/// once downloaded").
///
/// One store per app. A download runs at most once at a time: the Labs toggle
/// and a dictation start that finds no model share it, and either can cancel it.
public actor ParakeetModelStore {
    /// Where the model stands.
    public enum State: Equatable, Sendable {
        case notDownloaded
        /// Downloading, with the fraction done (0...1).
        case downloading(Double)
        /// Downloaded; compiling or loading for this Mac.
        case preparing
        /// On disk, with its size in bytes; dictation works offline.
        case ready(diskBytes: Int64)
        case failed(String)
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "dictation")
    private let directory: URL
    private var loaded: AsrModels?
    private var download: Task<AsrModels, any Error>?
    private var observer: (@Sendable (State) -> Void)?
    public private(set) var state: State = .notDownloaded

    /// Parakeet runs on the Neural Engine of Apple silicon only.
    public nonisolated static var isSupported: Bool { SystemInfo.isAppleSilicon }

    /// - Parameter directory: The model's own folder, for example
    ///   `~/Library/Application Support/cmux-next/speech-models/parakeet-v3`.
    ///   Made on any thread: the disk is read later, on the store's own executor (``refresh()``).
    public init(directory: URL) {
        self.directory = directory
    }

    /// Reads whether the model is on disk (and its size) when nothing is loading.
    public func refresh() {
        guard download == nil, loaded == nil else { return }
        set(AsrModels.modelsExist(at: directory, version: .v3) ? .ready(diskBytes: Self.diskBytes(directory)) : .notDownloaded)
    }

    /// Calls `observer` with each new state (on no particular thread).
    public func observe(_ observer: (@Sendable (State) -> Void)?) {
        self.observer = observer
    }

    /// Starts the download if the model is neither loaded nor downloading.
    public func prepare() {
        guard loaded == nil, download == nil else { return }
        _ = start()
    }

    /// The loaded model, downloading it first when it is not on disk.
    /// Cancelling the calling task does not cancel a shared download; ``cancel()`` does.
    func models() async throws -> AsrModels {
        if let loaded { return loaded }
        let task = download ?? start()
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            // A dictation start cancelled with Esc stops the download it began.
            task.cancel()
        }
    }

    /// Stops a running download; what was fetched stays for the next try.
    public func cancel() {
        download?.cancel()
    }

    /// Frees the loaded model's memory (the setting turned off); the files stay.
    public func unload() {
        download?.cancel()
        loaded = nil
    }

    private func start() -> Task<AsrModels, any Error> {
        let directory = directory
        // The task holds the store only while it downloads; it ends, so no cycle stays.
        let task = Task<AsrModels, any Error> {
            try await AsrModels.downloadAndLoad(to: directory, version: .v3) { progress in
                Task { await self.report(progress) }
            }
        }
        download = task
        // On disk already: a load, not a download; no progress to show.
        set(AsrModels.modelsExist(at: directory, version: .v3) ? .preparing : .downloading(0))
        Task { await settle(task) }
        return task
    }

    private func report(_ progress: DownloadProgress) {
        guard download != nil else { return }
        switch progress.phase {
        case .listing: set(.downloading(0))
        case .downloading: set(.downloading(min(max(progress.fractionCompleted, 0), 1)))
        case .compiling: set(.preparing)
        }
    }

    private func settle(_ task: Task<AsrModels, any Error>) async {
        let result = await task.result
        guard download == task else { return }
        download = nil
        switch result {
        case .success(let models):
            loaded = models
            set(.ready(diskBytes: Self.diskBytes(directory)))
        case .failure(let error) where error is CancellationError || task.isCancelled:
            Self.logger.info("parakeet model download cancelled")
            set(AsrModels.modelsExist(at: directory, version: .v3) ? .ready(diskBytes: Self.diskBytes(directory)) : .notDownloaded)
        case .failure(let error):
            Self.logger.error("parakeet model download failed: \(error.localizedDescription, privacy: .public)")
            set(.failed(error.localizedDescription))
        }
    }

    private func set(_ next: State) {
        guard next != state else { return }
        state = next
        observer?(next)
    }

    /// The size of everything under `directory`, as Finder counts it.
    static func diskBytes(_ directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let files = FileManager.checked.enumerator(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            guard let values = try? url.blockingResourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
