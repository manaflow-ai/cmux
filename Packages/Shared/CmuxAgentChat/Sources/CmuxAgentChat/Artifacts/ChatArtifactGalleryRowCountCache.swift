import Foundation

/// Caches authoritative gallery row counts for a short filesystem freshness window.
public actor ChatArtifactGalleryRowCountCache {
    private struct Key: Hashable {
        let sessionID: String
        let generation: String
        let includeDirectories: Bool
        let includeMissing: Bool
    }

    private struct Entry {
        let total: Int
        let storedAt: Date
    }

    private let maximumAge: TimeInterval
    private var entries: [Key: Entry] = [:]
    private var inFlightComputations: [Key: Task<Int, Never>] = [:]

    /// Creates a gallery row count cache.
    ///
    /// - Parameter maximumAge: Maximum age of a cached stat-derived count.
    public init(maximumAge: TimeInterval = 2) {
        self.maximumAge = max(0, maximumAge)
    }

    /// Returns the cached total, computing it at most once under concurrent
    /// misses: callers that land on the same (session, generation, filters)
    /// key await one shared sweep instead of issuing overlapping ones.
    public func total(
        sessionID: String,
        generation: String,
        includeDirectories: Bool,
        includeMissing: Bool,
        now: Date,
        compute: @escaping @Sendable () -> Int
    ) async -> Int {
        if let cached = total(
            sessionID: sessionID,
            generation: generation,
            includeDirectories: includeDirectories,
            includeMissing: includeMissing,
            now: now
        ) {
            return cached
        }
        let key = Key(
            sessionID: sessionID,
            generation: generation,
            includeDirectories: includeDirectories,
            includeMissing: includeMissing
        )
        if let inFlight = inFlightComputations[key] {
            return await inFlight.value
        }
        let task = Task<Int, Never>(priority: .utility) { compute() }
        inFlightComputations[key] = task
        let computed = await task.value
        inFlightComputations[key] = nil
        store(
            computed,
            sessionID: sessionID,
            generation: generation,
            includeDirectories: includeDirectories,
            includeMissing: includeMissing,
            now: Date()
        )
        return computed
    }

    /// Returns a fresh cached total for an exact snapshot and filter key.
    ///
    /// - Parameters:
    ///   - sessionID: Stable identity of the transcript session.
    ///   - generation: Transcript snapshot generation.
    ///   - includeDirectories: Whether the cached count includes directories.
    ///   - includeMissing: Whether the cached count includes missing references.
    ///   - now: Time used to enforce the cache's maximum age.
    /// - Returns: The cached total, or `nil` when absent or stale.
    public func total(
        sessionID: String,
        generation: String,
        includeDirectories: Bool,
        includeMissing: Bool,
        now: Date
    ) -> Int? {
        removeExpiredEntries(now: now)
        return entries[Key(
            sessionID: sessionID,
            generation: generation,
            includeDirectories: includeDirectories,
            includeMissing: includeMissing
        )]?.total
    }

    /// Stores a stat-derived total for an exact snapshot and filter key.
    ///
    /// A new generation or filter combination for the same session replaces
    /// that session's older count so the cache remains tiny.
    ///
    /// - Parameters:
    ///   - total: Authoritative gallery row total.
    ///   - sessionID: Stable identity of the transcript session.
    ///   - generation: Transcript snapshot generation.
    ///   - includeDirectories: Whether the count includes directories.
    ///   - includeMissing: Whether the count includes missing references.
    ///   - now: Time at which the count was computed.
    public func store(
        _ total: Int,
        sessionID: String,
        generation: String,
        includeDirectories: Bool,
        includeMissing: Bool,
        now: Date
    ) {
        removeExpiredEntries(now: now)
        entries = entries.filter { $0.key.sessionID != sessionID }
        entries[Key(
            sessionID: sessionID,
            generation: generation,
            includeDirectories: includeDirectories,
            includeMissing: includeMissing
        )] = Entry(total: total, storedAt: now)
    }

    private func removeExpiredEntries(now: Date) {
        entries = entries.filter {
            now.timeIntervalSince($0.value.storedAt) <= maximumAge
        }
    }
}
