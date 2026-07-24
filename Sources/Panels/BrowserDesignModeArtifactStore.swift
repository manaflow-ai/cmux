import Foundation

/// Persists design-mode handoff artifacts away from the main actor.
actor BrowserDesignModeArtifactStore {
    private static let fileLimit = 100
    private static let processLiveContextSessionID = String(UUID().uuidString.prefix(8))
    private static let handoffMarkerBasePrefix = ".handoff-"
    private static let releasedMarkerPrefix = ".released-"
    private static let screenshotSuffix = "screenshot.png"

    private let directory: URL
    private let fileManager: FileManager
    private let handoffMarkerPrefix: String
    private let liveContextSuffix: String

    init(
        directory: URL,
        fileManager: FileManager = .default,
        liveContextSessionID: String = processLiveContextSessionID
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.handoffMarkerPrefix = "\(Self.handoffMarkerBasePrefix)\(liveContextSessionID)-"
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
        guard fileManager.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    /// Validates and retains a handoff bundle across other stores' pruning.
    ///
    /// The caller releases the candidate if clipboard delivery fails, or the
    /// previous clipboard bundle after a later delivery replaces it.
    func retainHandoffArtifacts(at paths: [String]) -> Bool {
        let urls = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let standardizedDirectory = directory.standardizedFileURL
        guard !urls.isEmpty,
              urls.allSatisfy({
                  $0.deletingLastPathComponent() == standardizedDirectory
                      && !$0.lastPathComponent.hasPrefix(".")
                      && fileManager.fileExists(atPath: $0.path)
              }) else { return false }

        var retainedURLs: [URL] = []
        for url in urls {
            do {
                try Data().write(to: handoffMarkerURL(for: url), options: .atomic)
                retainedURLs.append(url)
            } catch {
                retainedURLs.forEach { removeHandoffMarker(for: $0) }
                return false
            }
        }
        guard urls.allSatisfy({ fileManager.fileExists(atPath: $0.path) }) else {
            retainedURLs.forEach { removeHandoffMarker(for: $0) }
            return false
        }
        return true
    }

    func releaseHandoff(_ paths: [String]) {
        paths
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .forEach { removeHandoffMarker(for: $0) }
        pruneKeepingNewest(limit: Self.fileLimit)
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
        let staleHandoffMarkerURLs = directoryURLs.filter {
            isHandoffMarker($0) && !isCurrentHandoffMarker($0)
        }
        staleHandoffMarkerURLs.forEach { try? fileManager.removeItem(at: $0) }
        let markerURLs = directoryURLs.filter {
            isReleasedMarker($0) || isCurrentHandoffMarker($0)
        }
        for markerURL in markerURLs where !fileManager.fileExists(
            atPath: artifactURL(forMarker: markerURL).path
        ) {
            try? fileManager.removeItem(at: markerURL)
        }
        let urls = directoryURLs.filter { !$0.lastPathComponent.hasPrefix(".") }
        guard urls.count > limit else { return }
        let pinnedCount = urls.reduce(into: 0) { count, url in
            if isRetained(url) { count += 1 }
        }
        let prunableLimit = max(0, limit - pinnedCount)
        let ordered = urls.filter { !isRetained($0) }.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }
        for staleURL in ordered.dropFirst(prunableLimit) {
            if !isRetained(staleURL) {
                removeArtifact(at: staleURL)
            }
        }
    }

    private func isLiveContext(_ url: URL) -> Bool {
        url.lastPathComponent.hasSuffix("-\(liveContextSuffix)")
            && !fileManager.fileExists(atPath: releasedMarkerURL(for: url).path)
    }

    private func isRetained(_ url: URL) -> Bool {
        isLiveContext(url)
            || fileManager.fileExists(atPath: handoffMarkerURL(for: url).path)
    }

    private func removeArtifact(at url: URL) {
        try? fileManager.removeItem(at: url)
        try? fileManager.removeItem(at: releasedMarkerURL(for: url))
        removeHandoffMarker(for: url)
    }

    private func handoffMarkerURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(
            "\(handoffMarkerPrefix)\(url.lastPathComponent)",
            isDirectory: false
        )
    }

    private func removeHandoffMarker(for url: URL) {
        try? fileManager.removeItem(at: handoffMarkerURL(for: url))
    }

    private func releasedMarkerURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(
            "\(Self.releasedMarkerPrefix)\(url.lastPathComponent)",
            isDirectory: false
        )
    }

    private func artifactURL(forMarker markerURL: URL) -> URL {
        let filename = markerURL.lastPathComponent.dropFirst(
            isReleasedMarker(markerURL)
                ? Self.releasedMarkerPrefix.count
                : handoffMarkerPrefix.count
        )
        return markerURL.deletingLastPathComponent().appendingPathComponent(
            String(filename),
            isDirectory: false
        )
    }

    private func isReleasedMarker(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix(Self.releasedMarkerPrefix)
    }

    private func isHandoffMarker(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix(Self.handoffMarkerBasePrefix)
    }

    private func isCurrentHandoffMarker(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix(handoffMarkerPrefix)
    }
}
