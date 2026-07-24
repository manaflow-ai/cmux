import Foundation

/// Persists design-mode handoff artifacts away from the main actor.
actor BrowserDesignModeArtifactStore {
    private static let fileLimit = 100
    private static let processLiveContextSessionID = String(UUID().uuidString.prefix(8))
    private static let screenshotSuffix = "screenshot.png"

    private let directory: URL
    private let fileManager: FileManager
    private let liveContextSuffix: String

    init(
        directory: URL,
        fileManager: FileManager = .default,
        liveContextSessionID: String = processLiveContextSessionID
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.liveContextSuffix = "live-context-\(liveContextSessionID).png"
    }

    func saveScreenshot(
        _ pngData: Data,
        surfaceID: UUID,
        retention: BrowserDesignModeArtifactRetention = .prunable
    ) throws -> URL {
        try save(
            pngData,
            surfaceID: surfaceID,
            filenameSuffix: retention == .liveContext
                ? liveContextSuffix
                : Self.screenshotSuffix
        )
    }

    func saveContextJSON(_ jsonData: Data, surfaceID: UUID) throws -> URL {
        try save(
            jsonData,
            surfaceID: surfaceID,
            filenameSuffix: "context.json"
        )
    }

    private func save(
        _ data: Data,
        surfaceID: UUID,
        filenameSuffix: String
    ) throws -> URL {
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        let filename = [
            "surface-\(surfaceID.uuidString.prefix(8))",
            "\(timestamp)",
            "\(UUID().uuidString.prefix(8))",
            filenameSuffix,
        ].joined(separator: "-")
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        pruneKeepingNewest(limit: Self.fileLimit)
        return url
    }

    /// Deletes a capture that never became part of authoritative prompt context.
    func remove(_ url: URL) {
        try? fileManager.removeItem(at: url)
    }

    /// Returns a former live-context file to normal recency-based pruning.
    func release(_ url: URL) {
        if isLiveContext(url) {
            let releasedURL = url.deletingLastPathComponent().appendingPathComponent(
                url.lastPathComponent.replacingOccurrences(
                    of: liveContextSuffix,
                    with: Self.screenshotSuffix
                )
            )
            do {
                try fileManager.moveItem(at: url, to: releasedURL)
            } catch {
                try? fileManager.removeItem(at: url)
            }
        }
        pruneKeepingNewest(limit: Self.fileLimit)
    }

    private func pruneKeepingNewest(limit: Int) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), urls.count > limit else { return }
        let pinnedCount = urls.reduce(into: 0) { count, url in
            if isLiveContext(url) { count += 1 }
        }
        let prunableLimit = max(0, limit - pinnedCount)
        let ordered = urls.filter { !isLiveContext($0) }.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }
        for staleURL in ordered.dropFirst(prunableLimit) {
            try? fileManager.removeItem(at: staleURL)
        }
    }

    private func isLiveContext(_ url: URL) -> Bool {
        url.lastPathComponent.hasSuffix("-\(liveContextSuffix)")
    }
}
