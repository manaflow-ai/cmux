import Foundation

enum BrowserDesignModeScreenshotRetention: Equatable, Sendable {
    case prunable
    case liveContext
}

/// Coordinates live-context files across per-panel stores sharing one directory.
private actor BrowserDesignModeScreenshotPinRegistry {
    static let shared = BrowserDesignModeScreenshotPinRegistry()

    private var paths: Set<String> = []

    func retain(_ url: URL) {
        paths.insert(url.standardizedFileURL.path)
    }

    func release(_ url: URL) {
        paths.remove(url.standardizedFileURL.path)
    }

    func snapshot() -> Set<String> {
        paths
    }
}

/// Persists bounded screenshot crops away from the main actor.
actor BrowserDesignModeScreenshotStore {
    private static let fileLimit = 100

    private let directory: URL
    private let fileManager: FileManager
    private let pinRegistry = BrowserDesignModeScreenshotPinRegistry.shared

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    func save(
        _ pngData: Data,
        surfaceID: UUID,
        retention: BrowserDesignModeScreenshotRetention = .prunable
    ) async throws -> URL {
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        let filename = "surface-\(surfaceID.uuidString.prefix(8))-\(timestamp)-\(UUID().uuidString.prefix(8)).png"
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        if retention == .liveContext {
            await pinRegistry.retain(url)
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try pngData.write(to: url, options: .atomic)
        } catch {
            await pinRegistry.release(url)
            throw error
        }
        await pruneKeepingNewest(limit: Self.fileLimit)
        return url
    }

    /// Deletes a capture that never became part of authoritative prompt context.
    func remove(_ url: URL) async {
        await pinRegistry.release(url)
        try? fileManager.removeItem(at: url)
    }

    /// Returns a former live-context file to normal recency-based pruning.
    func release(_ url: URL) async {
        await pinRegistry.release(url)
        await pruneKeepingNewest(limit: Self.fileLimit)
    }

    private func pruneKeepingNewest(limit: Int) async {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), urls.count > limit else { return }
        let pinnedPaths = await pinRegistry.snapshot()
        let pinnedCount = urls.reduce(into: 0) { count, url in
            if pinnedPaths.contains(url.standardizedFileURL.path) { count += 1 }
        }
        let prunableLimit = max(0, limit - pinnedCount)
        let ordered = urls.filter {
            !pinnedPaths.contains($0.standardizedFileURL.path)
        }.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }
        for staleURL in ordered.dropFirst(prunableLimit) {
            try? fileManager.removeItem(at: staleURL)
        }
    }
}
