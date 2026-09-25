import Foundation

/// Emits Mac mirror dimensions only when the source terminal's actual grid changes.
/// Global Ghostty ticks can replace named render notifications, so they sample
/// the cached live surface IDs without sending a replay or render-grid frame.
@MainActor
struct DeviceTerminalGridPublisher {
    nonisolated static let eventTopic = "device.terminal.grid"

    struct Grid: Equatable, Sendable {
        let columns: Int
        let rows: Int
        let generation: UInt64
    }

    private var topologyGeneration: UInt64?
    private var liveSurfaceIDs = Set<UUID>()
    private var grids: [UUID: Grid] = [:]

    mutating func refresh(
        updatedSurfaceIDs: Set<UUID>,
        global: Bool,
        topologyGeneration: UInt64,
        allSurfaceIDs: () -> Set<UUID>,
        sample: (UUID) -> Grid?,
        publish: (UUID, Grid) -> Void
    ) {
        if self.topologyGeneration != topologyGeneration {
            liveSurfaceIDs = allSurfaceIDs()
            grids = grids.filter { liveSurfaceIDs.contains($0.key) }
            self.topologyGeneration = topologyGeneration
        }
        for id in global ? liveSurfaceIDs : updatedSurfaceIDs {
            guard liveSurfaceIDs.contains(id), let grid = sample(id),
                  (1...Int(UInt16.max)).contains(grid.columns),
                  (1...Int(UInt16.max)).contains(grid.rows), grids[id] != grid else { continue }
            grids[id] = grid
            publish(id, grid)
        }
    }

    mutating func reset() {
        guard topologyGeneration != nil else { return }
        topologyGeneration = nil
        liveSurfaceIDs.removeAll()
        grids.removeAll()
    }
}
