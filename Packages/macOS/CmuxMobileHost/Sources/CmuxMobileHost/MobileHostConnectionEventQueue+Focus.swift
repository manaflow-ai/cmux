import Foundation

extension MobileHostConnectionEventQueue {
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
            let generation = surfaceLaneGenerations[surfaceID, default: 0] &+ 1
            surfaceLaneGenerations[surfaceID] = generation
            var dropped = MobileHostEventShedSummary()
            removeRenderGridEventsLocked(surfaceIDs: [surfaceID], summary: &dropped)
            poisonedRenderGridSurfaceIDs.insert(surfaceID)
            released[surfaceID] = generation
        }
        return released
    }
}
