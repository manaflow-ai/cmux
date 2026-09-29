import Foundation

extension MobileHostConnectionEventQueue {
    // Focus routing stays separate from mailbox admission to keep both files
    // within the repository's Swift file-length budget.

    /// One key per terminal: focus signals and render-grid events can differ
    /// in case or surrounding whitespace.
    public static func canonicalSurfaceKey(_ rawSurfaceKey: String) -> String {
        let trimmed = rawSurfaceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return UUID(uuidString: trimmed)?.uuidString ?? trimmed.lowercased()
    }

    /// Gives a focused surface its own lane and releases the least recently
    /// focused surface when the limit is exceeded. Released frames are
    /// poisoned so the producer must rebase with a full frame on the shared
    /// lane; the writer resets the old native stream separately.
    public func focusSurfaceLane(_ rawSurfaceKey: String) -> [String: UInt64] {
        let key = Self.canonicalSurfaceKey(rawSurfaceKey)
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, surfaceLaneLimit > 0, !key.isEmpty else { return [:] }
        if let index = focusedSurfaceKeys.firstIndex(of: key) {
            focusedSurfaceKeys.remove(at: index)
        }
        focusedSurfaceKeys.append(key)
        var released: [String: UInt64] = [:]
        while focusedSurfaceKeys.count > surfaceLaneLimit {
            let victim = focusedSurfaceKeys.removeFirst()
            guard let surfaceID = surfaceLaneCoalesceKeysByCanonicalKey
                .removeValue(forKey: victim) else { continue }
            let generation = surfaceLaneGenerations[victim, default: 0] &+ 1
            surfaceLaneGenerations[victim] = generation
            var dropped = MobileHostEventShedSummary()
            removeRenderGridEventsLocked(surfaceIDs: [victim], summary: &dropped)
            poisonedRenderGridSurfaceIDs.insert(victim)
            released[surfaceID] = generation
        }
        return released
    }

    /// Pins a surface to the shared lane when a native open cannot fit while
    /// another stream is still retiring. The failed surface event is dropped
    /// and a full frame re-bases the chain on the shared stream.
    public func pinSurfaceLaneToShared(surfaceID rawSurfaceID: String, generation: UInt64) -> Set<String> {
        let key = Self.canonicalSurfaceKey(rawSurfaceID)
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, surfaceLaneGenerations[key, default: 0] == generation else { return [] }
        sharedLanePinnedSurfaceIDs.insert(key)
        surfaceLaneGenerations[key] = generation &+ 1
        var dropped = MobileHostEventShedSummary()
        removeRenderGridEventsLocked(surfaceIDs: [key], summary: &dropped)
        poisonedRenderGridSurfaceIDs.insert(key)
        return [key]
    }
}
