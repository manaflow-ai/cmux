import Foundation

extension DaemonConnection {
    /// Starts a shell in each of the kept tabs `surfaces` in place, together (`restart-tab` of a
    /// dead tab with the workspace store's `relaunch` record: End Sessions, Keep Layout, or a tab
    /// `park-tabs` parked). Each keeps its tab id, slot, name, pin and group under the same
    /// terminal id, and its shell starts in the record's directory (else home), so the pane, its
    /// split and ratio never change. Each `restart-tab` answers when its worker started, so the
    /// pane maps its restored tabs once, not once per create, move and close in turn
    /// (cx-8w027.23). The caller passes the tabs of one shown workspace (`DaemonService.startKeptTabs`):
    /// a hidden workspace's kept tabs start when it is shown, never at connect (#17587).
    /// - Parameter surfaces: The dead kept tabs to start.
    /// - Returns: The tabs the daemon refused, each with its failure line (they stay dead).
    public func restartKeptTabs(_ surfaces: [SurfaceID]) async -> [SurfaceID: String] {
        await withTaskGroup(of: (SurfaceID, String)?.self) { group in
            for surface in surfaces {
                group.addTask { await self.restartKeptTab(surface) }
            }
            var refused: [SurfaceID: String] = [:]
            for await failure in group {
                if let failure { refused[failure.0] = failure.1 }
            }
            return refused
        }
    }

    /// One kept tab's `restart-tab`: nil when the daemon took it, else the tab and the failure line.
    private func restartKeptTab(_ surface: SurfaceID) async -> (SurfaceID, String)? {
        do {
            _ = try await request(RestartTabRequest(surface: surface))
            return nil
        } catch {
            return (surface, "surface \(surface.rawValue): \(error)")
        }
    }
}
