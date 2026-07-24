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
        retention: BrowserDesignModeArtifactRetention = .prunable,
        handoffLease: UUID? = nil
    ) throws -> URL {
        try save(
            pngData,
            surfaceID: surfaceID,
            filenameSuffix: retention == .liveContext
                ? liveContextSuffix
                : Self.screenshotSuffix,
            handoffLease: handoffLease
        )
    }

    func saveContextJSON(
        _ jsonData: Data,
        surfaceID: UUID,
        handoffLease: UUID? = nil
    ) throws -> URL {
        try save(
            jsonData,
            surfaceID: surfaceID,
            filenameSuffix: "context.json",
            handoffLease: handoffLease
        )
    }

    func beginHandoff() -> UUID {
        UUID()
    }

    private func save(
        _ data: Data,
        surfaceID: UUID,
        filenameSuffix: String,
        handoffLease: UUID?
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
        if let handoffLease {
            do {
                try Data().write(
                    to: handoffMarkerURL(for: url, lease: handoffLease),
                    options: .atomic
                )
            } catch {
                removeArtifact(at: url)
                throw error
            }
        }
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
    func retainHandoffArtifacts(at paths: [String], lease: UUID) -> Bool {
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
                try Data().write(
                    to: handoffMarkerURL(for: url, lease: lease),
                    options: .atomic
                )
                retainedURLs.append(url)
            } catch {
                retainedURLs.forEach { removeHandoffMarker(for: $0, lease: lease) }
                return false
            }
        }
        guard urls.allSatisfy({ fileManager.fileExists(atPath: $0.path) }) else {
            retainedURLs.forEach { removeHandoffMarker(for: $0, lease: lease) }
            return false
        }
        return true
    }

    func releaseHandoff(_ lease: UUID) {
        guard let directoryURLs = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        let leaseMarkerPrefix = "\(handoffMarkerPrefix)\(lease.uuidString)-"
        for markerURL in directoryURLs where markerURL.lastPathComponent.hasPrefix(leaseMarkerPrefix) {
            try? fileManager.removeItem(at: markerURL)
        }
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
        var handoffArtifactNames = Set<String>()
        for markerURL in markerURLs {
            guard let artifactURL = artifactURL(forMarker: markerURL),
                  fileManager.fileExists(atPath: artifactURL.path) else {
                try? fileManager.removeItem(at: markerURL)
                continue
            }
            if isCurrentHandoffMarker(markerURL) {
                handoffArtifactNames.insert(artifactURL.lastPathComponent)
            }
        }
        let urls = directoryURLs.filter { !$0.lastPathComponent.hasPrefix(".") }
        guard urls.count > limit else { return }
        let pinnedCount = urls.reduce(into: 0) { count, url in
            if isRetained(url, handoffArtifactNames: handoffArtifactNames) { count += 1 }
        }
        let prunableLimit = max(0, limit - pinnedCount)
        let ordered = urls.filter {
            !isRetained($0, handoffArtifactNames: handoffArtifactNames)
        }.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }
        for staleURL in ordered.dropFirst(prunableLimit) {
            if !isRetained(staleURL, handoffArtifactNames: handoffArtifactNames) {
                removeArtifact(at: staleURL)
            }
        }
    }

    private func isLiveContext(_ url: URL) -> Bool {
        url.lastPathComponent.hasSuffix("-\(liveContextSuffix)")
            && !fileManager.fileExists(atPath: releasedMarkerURL(for: url).path)
    }

    private func isRetained(
        _ url: URL,
        handoffArtifactNames: Set<String>
    ) -> Bool {
        isLiveContext(url)
            || handoffArtifactNames.contains(url.lastPathComponent)
    }

    private func removeArtifact(at url: URL) {
        try? fileManager.removeItem(at: url)
        try? fileManager.removeItem(at: releasedMarkerURL(for: url))
        removeHandoffMarkers(for: url)
    }

    private func handoffMarkerURL(for url: URL, lease: UUID) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(
            "\(handoffMarkerPrefix)\(lease.uuidString)-\(url.lastPathComponent)",
            isDirectory: false
        )
    }

    private func removeHandoffMarker(for url: URL, lease: UUID) {
        try? fileManager.removeItem(at: handoffMarkerURL(for: url, lease: lease))
    }

    private func removeHandoffMarkers(for url: URL) {
        guard let directoryURLs = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for markerURL in directoryURLs where isCurrentHandoffMarker(markerURL)
            && artifactURL(forMarker: markerURL)?.standardizedFileURL == url.standardizedFileURL {
            try? fileManager.removeItem(at: markerURL)
        }
    }

    private func releasedMarkerURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(
            "\(Self.releasedMarkerPrefix)\(url.lastPathComponent)",
            isDirectory: false
        )
    }

    private func artifactURL(forMarker markerURL: URL) -> URL? {
        let filename: Substring
        if isReleasedMarker(markerURL) {
            filename = markerURL.lastPathComponent.dropFirst(Self.releasedMarkerPrefix.count)
        } else {
            let leaseAndFilename = markerURL.lastPathComponent.dropFirst(handoffMarkerPrefix.count)
            guard leaseAndFilename.count > 37 else { return nil }
            let separator = leaseAndFilename.index(leaseAndFilename.startIndex, offsetBy: 36)
            guard leaseAndFilename[separator] == "-",
                  UUID(uuidString: String(leaseAndFilename[..<separator])) != nil else {
                return nil
            }
            filename = leaseAndFilename.dropFirst(37)
        }
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
