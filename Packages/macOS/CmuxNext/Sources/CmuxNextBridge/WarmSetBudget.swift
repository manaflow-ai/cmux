public import CmuxNextCompat
import Foundation

/// How much hidden content stays warm (architecture.md section 4): the one
/// memory budget of hidden GPU surfaces. A window keeps the workspaces it
/// showed most recently mounted (tree, panes, strips; `ParkedWorkspaceBudget`,
/// 32 per window), and its hidden terminal
/// surfaces, in the shown workspace's other tabs and in parked workspaces
/// alike, are kept in one LRU of `terminalCapacity` (`SurfaceLedger`); an
/// evicted one re-attaches with a daemon replay when its pane shows again.
/// Sized from physical memory and shrunk under memory pressure.
public struct WarmSetBudget: Hashable, Sendable {
    /// Hidden terminal surfaces kept beyond the visible ones (LRU).
    public var terminalCapacity: Int

    public init(terminalCapacity: Int) {
        self.terminalCapacity = max(0, terminalCapacity)
    }

    /// Measured cost of one hidden terminal surface in the app's footprint
    /// (triple-buffered IOSurfaces at a 1100x720 point window on a 2x
    /// display, grid, atlas share): about 48 MB.
    public static let terminalCostBytes: UInt64 = 48 << 20

    /// 1/64 of physical memory for hidden terminal surfaces (8 to 24: the
    /// envelope the surfaces and the parked workspaces' panes had together
    /// before parked workspaces stopped having their own budget). Under a
    /// pressure warning 6; critical keeps only what shows.
    public static func forMemory(physicalBytes: UInt64, pressure: MemoryPressureLevel) -> WarmSetBudget {
        switch pressure {
        case .critical:
            return WarmSetBudget(terminalCapacity: 0)
        case .warning:
            return WarmSetBudget(terminalCapacity: 6)
        case .normal:
            return WarmSetBudget(terminalCapacity: min(24, max(8, Int((physicalBytes / 64) / terminalCostBytes))))
        }
    }

    public static func current(pressure: MemoryPressureLevel = .normal) -> WarmSetBudget {
        forMemory(physicalBytes: ProcessInfo.processInfo.physicalMemory, pressure: pressure)
    }

    public static let standard = current()
}
