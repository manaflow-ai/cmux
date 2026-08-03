public import Foundation
public import Observation

/// Owns the downloadable Parakeet model stores.
@MainActor
@Observable
public final class ParakeetModelCatalogStore {
    /// Per-model stores in settings display order.
    public let stores: [ParakeetModelStore]

    /// Creates stores for all downloadable Parakeet engines.
    public init(
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default,
        downloader: any ParakeetModelDownloading = FluidAudioParakeetModelDownloader()
    ) {
        self.stores = ParakeetModelDescriptor.allDownloadable.map { descriptor in
            ParakeetModelStore(
                descriptor: descriptor,
                applicationSupportDirectory: applicationSupportDirectory,
                fileManager: fileManager,
                downloader: downloader
            )
        }
    }

    /// Test initializer for explicitly constructed stores.
    public init(stores: [ParakeetModelStore]) {
        self.stores = stores
    }

    /// Whether any model is currently downloading.
    public var isDownloadingAnyModel: Bool {
        stores.contains { $0.state.isDownloading }
    }

    /// Installed downloadable engines.
    public var installedEngineIDs: Set<VoiceEngineID> {
        Set(stores.filter(\.isInstalled).map(\.engineID))
    }

    /// Store for one engine.
    public func store(for engineID: VoiceEngineID) -> ParakeetModelStore? {
        stores.first { $0.engineID == engineID }
    }

    /// Starts a model download if no other model is already downloading.
    public func downloadModel(for engineID: VoiceEngineID) {
        guard !isDownloadingAnyModel, let store = store(for: engineID) else { return }
        store.downloadModel()
    }

    /// Deletes one model and refreshes sibling install states.
    public func deleteModel(for engineID: VoiceEngineID) throws {
        guard let store = store(for: engineID) else { return }
        let preserveSharedFiles = stores.contains { candidate in
            candidate.engineID != engineID
                && candidate.modelDirectory == store.modelDirectory
                && (candidate.isInstalled || candidate.state.isDownloading)
        }
        try store.deleteModel(preservingSharedFiles: preserveSharedFiles)
        refreshInstalledStates()
    }

    /// Refreshes all stores from disk.
    public func refreshInstalledStates() {
        for store in stores {
            store.refreshInstalledState()
        }
    }
}
