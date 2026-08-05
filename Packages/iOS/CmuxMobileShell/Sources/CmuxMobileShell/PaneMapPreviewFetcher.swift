internal import CMUXMobileCore

/// Schedules pane-map replay snapshots with a bounded request window.
///
/// Selected surfaces are placed first, duplicates keep their first position,
/// and cancellation prevents queued work from entering the active window.
struct PaneMapPreviewFetcher: Sendable {
    let maximumConcurrentRequests: Int

    init(maximumConcurrentRequests: Int = 4) {
        self.maximumConcurrentRequests = max(1, maximumConcurrentRequests)
    }

    func fetch(
        selectedSurfaceIDs: [String],
        remainingSurfaceIDs: [String],
        fetchGrid: @escaping @Sendable (String) async -> MobileTerminalRenderGridFrame?
    ) async -> [String: MobileTerminalRenderGridFrame] {
        let surfaceIDs = orderedSurfaceIDs(
            selectedSurfaceIDs: selectedSurfaceIDs,
            remainingSurfaceIDs: remainingSurfaceIDs
        )
        guard !surfaceIDs.isEmpty, !Task.isCancelled else { return [:] }

        return await withTaskGroup(
            of: (String, MobileTerminalRenderGridFrame?).self,
            returning: [String: MobileTerminalRenderGridFrame].self
        ) { group in
            var nextIndex = 0

            func enqueueNext() {
                guard !Task.isCancelled, nextIndex < surfaceIDs.count else { return }
                let surfaceID = surfaceIDs[nextIndex]
                nextIndex += 1
                group.addTask {
                    guard !Task.isCancelled else { return (surfaceID, nil) }
                    return (surfaceID, await fetchGrid(surfaceID))
                }
            }

            for _ in 0..<min(maximumConcurrentRequests, surfaceIDs.count) {
                enqueueNext()
            }

            var gridsBySurfaceID: [String: MobileTerminalRenderGridFrame] = [:]
            while !Task.isCancelled,
                  let (surfaceID, grid) = await group.next() {
                if let grid {
                    gridsBySurfaceID[surfaceID] = grid
                }
                enqueueNext()
            }
            if Task.isCancelled {
                group.cancelAll()
            }
            return gridsBySurfaceID
        }
    }

    private func orderedSurfaceIDs(
        selectedSurfaceIDs: [String],
        remainingSurfaceIDs: [String]
    ) -> [String] {
        var seenSurfaceIDs: Set<String> = []
        var result: [String] = []
        result.reserveCapacity(selectedSurfaceIDs.count + remainingSurfaceIDs.count)
        for surfaceID in selectedSurfaceIDs where seenSurfaceIDs.insert(surfaceID).inserted {
            result.append(surfaceID)
        }
        for surfaceID in remainingSurfaceIDs where seenSurfaceIDs.insert(surfaceID).inserted {
            result.append(surfaceID)
        }
        return result
    }
}
