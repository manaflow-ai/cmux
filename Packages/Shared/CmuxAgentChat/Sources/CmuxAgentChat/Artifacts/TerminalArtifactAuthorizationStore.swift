import Foundation

/// Retains bounded terminal-scan generations for subsequent artifact reads.
public actor TerminalArtifactAuthorizationStore {
    private typealias Generation = (
        ordinal: UInt64,
        canonicalPaths: Set<String>,
        expiresAt: Date
    )

    private let timeToLive: TimeInterval
    private let maximumGenerationsPerSurface: Int
    private let maximumSurfaceCount: Int
    private var generationsBySurfaceKey: [String: [Generation]] = [:]
    private var nextOrdinalBySurfaceKey: [String: UInt64] = [:]
    private var lastAccessBySurfaceKey: [String: Date] = [:]

    /// Creates a bounded authorization store.
    ///
    /// - Parameters:
    ///   - timeToLive: Lifetime of each scan generation in seconds.
    ///   - maximumGenerationsPerSurface: Maximum concurrent listings retained for one surface.
    ///   - maximumSurfaceCount: Maximum terminal surfaces retained at once.
    public init(
        timeToLive: TimeInterval = 10 * 60,
        maximumGenerationsPerSurface: Int = 4,
        maximumSurfaceCount: Int = 64
    ) {
        self.timeToLive = max(1, timeToLive)
        self.maximumGenerationsPerSurface = max(1, maximumGenerationsPerSurface)
        self.maximumSurfaceCount = max(1, maximumSurfaceCount)
    }

    /// Records one canonical terminal-scan generation.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace containing the scanned terminal.
    ///   - surfaceID: Scanned terminal surface.
    ///   - canonicalPaths: Canonical paths returned to the listing client.
    ///   - date: Scan completion time.
    public func record(
        workspaceID: String,
        surfaceID: String,
        canonicalPaths: Set<String>,
        at date: Date = Date()
    ) {
        purgeExpired(at: date)
        let key = surfaceKey(workspaceID: workspaceID, surfaceID: surfaceID)
        let ordinal = (nextOrdinalBySurfaceKey[key] ?? 0) &+ 1
        nextOrdinalBySurfaceKey[key] = ordinal
        var generations = generationsBySurfaceKey[key] ?? []
        generations.append((
            ordinal: ordinal,
            canonicalPaths: canonicalPaths,
            expiresAt: date.addingTimeInterval(timeToLive)
        ))
        if generations.count > maximumGenerationsPerSurface {
            generations.removeFirst(generations.count - maximumGenerationsPerSurface)
        }
        generationsBySurfaceKey[key] = generations
        lastAccessBySurfaceKey[key] = date
        evictLeastRecentSurfacesIfNeeded()
    }

    /// Returns the union of unexpired scan generations for one terminal.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace containing the terminal.
    ///   - surfaceID: Terminal surface being read.
    ///   - date: Read time used for deterministic expiry.
    /// - Returns: Canonical paths listed by retained scan generations.
    public func authorizedPaths(
        workspaceID: String,
        surfaceID: String,
        at date: Date = Date()
    ) -> Set<String> {
        purgeExpired(at: date)
        let key = surfaceKey(workspaceID: workspaceID, surfaceID: surfaceID)
        guard let generations = generationsBySurfaceKey[key] else { return [] }
        lastAccessBySurfaceKey[key] = date
        return generations.reduce(into: Set<String>()) { result, generation in
            result.formUnion(generation.canonicalPaths)
        }
    }

    private func surfaceKey(workspaceID: String, surfaceID: String) -> String {
        "\(workspaceID)\u{0}\(surfaceID)"
    }

    private func purgeExpired(at date: Date) {
        for key in Array(generationsBySurfaceKey.keys) {
            let retained = generationsBySurfaceKey[key, default: []]
                .filter { $0.expiresAt > date }
            if retained.isEmpty {
                generationsBySurfaceKey.removeValue(forKey: key)
                nextOrdinalBySurfaceKey.removeValue(forKey: key)
                lastAccessBySurfaceKey.removeValue(forKey: key)
            } else {
                generationsBySurfaceKey[key] = retained
            }
        }
    }

    private func evictLeastRecentSurfacesIfNeeded() {
        while generationsBySurfaceKey.count > maximumSurfaceCount,
              let oldestKey = lastAccessBySurfaceKey.min(by: { $0.value < $1.value })?.key {
            generationsBySurfaceKey.removeValue(forKey: oldestKey)
            nextOrdinalBySurfaceKey.removeValue(forKey: oldestKey)
            lastAccessBySurfaceKey.removeValue(forKey: oldestKey)
        }
    }
}
