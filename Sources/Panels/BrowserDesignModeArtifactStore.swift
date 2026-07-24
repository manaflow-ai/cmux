import Foundation

/// Persists design-mode handoff artifacts away from the main actor.
actor BrowserDesignModeArtifactStore {
    private static let fileLimit = 100
    private static let processLiveContextSessionID = String(UUID().uuidString.prefix(8))
    private static let releasedMarkerPrefix = ".released-"
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
        removeArtifact(at: url)
    }

    /// Makes a former live-context file prunable without changing its handed-off path.
    func release(_ url: URL) {
        if url.lastPathComponent.hasSuffix("-\(liveContextSuffix)"),
           fileManager.fileExists(atPath: url.path) {
            try? Data().write(to: releasedMarkerURL(for: url), options: .atomic)
        }
        pruneKeepingNewest(limit: Self.fileLimit)
    }

    private func pruneKeepingNewest(limit: Int) {
        guard let directoryURLs = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else { return }
        let markerURLs = directoryURLs.filter(isReleasedMarker)
        for markerURL in markerURLs where !fileManager.fileExists(
            atPath: artifactURL(forReleasedMarker: markerURL).path
        ) {
            try? fileManager.removeItem(at: markerURL)
        }
        let urls = directoryURLs.filter { !$0.lastPathComponent.hasPrefix(".") }
        guard urls.count > limit else { return }
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
            removeArtifact(at: staleURL)
        }
    }

    private func isLiveContext(_ url: URL) -> Bool {
        url.lastPathComponent.hasSuffix("-\(liveContextSuffix)")
            && !fileManager.fileExists(atPath: releasedMarkerURL(for: url).path)
    }

    private func removeArtifact(at url: URL) {
        try? fileManager.removeItem(at: url)
        try? fileManager.removeItem(at: releasedMarkerURL(for: url))
    }

    private func releasedMarkerURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(
            "\(Self.releasedMarkerPrefix)\(url.lastPathComponent)",
            isDirectory: false
        )
    }

    private func artifactURL(forReleasedMarker markerURL: URL) -> URL {
        let filename = markerURL.lastPathComponent.dropFirst(Self.releasedMarkerPrefix.count)
        return markerURL.deletingLastPathComponent().appendingPathComponent(
            String(filename),
            isDirectory: false
        )
    }

    private func isReleasedMarker(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix(Self.releasedMarkerPrefix)
    }
}
