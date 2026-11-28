import Foundation

/// The system's memory pressure, from the memory pressure dispatch source
/// (never polled).
public enum MemoryPressureLevel: String, Hashable, Sendable, Codable {
    case normal, warning, critical
}

/// How much hidden content stays warm (architecture.md section 4): hidden
/// terminal surfaces kept alive for instant switching, and parked
/// workspaces (a window's recently shown workspaces kept mounted, paused).
/// Sized from physical memory and shrunk under memory pressure.
public struct WarmSetBudget: Hashable, Sendable {
    /// Hidden terminal surfaces kept beyond the visible ones (LRU).
    public var terminalCapacity: Int
    /// Recently shown workspaces kept mounted per window, besides the shown one.
    public var parkedWorkspaces: Int
    /// Panes all parked workspaces of a window may hold together (each pane
    /// keeps one surface or page mounted): many small workspaces stay warm,
    /// a few large ones do not crowd memory.
    public var parkedPanes: Int

    public init(terminalCapacity: Int, parkedWorkspaces: Int, parkedPanes: Int) {
        self.terminalCapacity = max(0, terminalCapacity)
        self.parkedWorkspaces = max(0, parkedWorkspaces)
        self.parkedPanes = max(0, parkedPanes)
    }

    /// Measured cost of one hidden terminal surface in the app's footprint
    /// (triple-buffered IOSurfaces at a 1100x720 point window on a 2x
    /// display, grid, atlas share): about 48 MB.
    public static let terminalCostBytes: UInt64 = 48 << 20

    /// 1/128 of physical memory for hidden terminal surfaces (4 to 12), and
    /// as many panes again for parked workspaces (at most 8 workspaces).
    /// Under a pressure warning 4 surfaces and one parked workspace of up
    /// to 2 panes; critical keeps only what shows.
    public static func forMemory(physicalBytes: UInt64, pressure: MemoryPressureLevel) -> WarmSetBudget {
        switch pressure {
        case .critical:
            return WarmSetBudget(terminalCapacity: 0, parkedWorkspaces: 0, parkedPanes: 0)
        case .warning:
            return WarmSetBudget(terminalCapacity: 4, parkedWorkspaces: 1, parkedPanes: 2)
        case .normal:
            let surfaces = min(12, max(4, Int((physicalBytes / 128) / terminalCostBytes)))
            return WarmSetBudget(terminalCapacity: surfaces, parkedWorkspaces: 8, parkedPanes: surfaces)
        }
    }

    public static func current(pressure: MemoryPressureLevel = .normal) -> WarmSetBudget {
        forMemory(physicalBytes: ProcessInfo.processInfo.physicalMemory, pressure: pressure)
    }

    public static let standard = current()
}
