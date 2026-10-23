import Foundation

/// The system's memory pressure, from the memory pressure dispatch source
/// (never polled).
public enum MemoryPressureLevel: String, Hashable, Sendable, Codable {
    case normal, warning, critical
}

/// How much hidden content stays warm (architecture.md section 4): the one
/// memory budget of hidden content. A window keeps every workspace it
/// showed mounted (tree, panes, strips; no budget), and its hidden terminal
/// surfaces, in the shown workspace's other tabs and in parked workspaces
/// alike, are kept in one LRU of `terminalCapacity` (`SurfaceLedger`); an
/// evicted one re-attaches with a daemon replay when its pane shows again.
/// Hidden live web pages past `pageCapacity` hibernate (`HibernationPlanner`):
/// the rest keeps its renderer until the `browser.hibernation` timeout.
/// Sized from physical memory and shrunk under memory pressure.
public struct WarmSetBudget: Hashable, Sendable {
    /// Hidden terminal surfaces kept beyond the visible ones (LRU).
    public var terminalCapacity: Int
    /// Hidden live web pages (either engine) kept beyond the shown ones, their neighbors and
    /// each pane's shown tab; the least valuable of the others hibernate.
    public var pageCapacity: Int

    public init(terminalCapacity: Int, pageCapacity: Int = WarmSetBudget.minimumPages) {
        self.terminalCapacity = max(0, terminalCapacity)
        self.pageCapacity = max(0, pageCapacity)
    }

    /// Measured cost of one hidden terminal surface in the app's footprint
    /// (triple-buffered IOSurfaces at a 1100x720 point window on a 2x
    /// display, grid, atlas share): about 48 MB.
    public static let terminalCostBytes: UInt64 = 48 << 20

    /// 1/64 of physical memory for hidden terminal surfaces (8 to 24: the
    /// envelope the surfaces and the parked workspaces' panes had together
    /// before parked workspaces stopped having their own budget), and 1/64 for
    /// hidden live pages (4 to 16). Under a pressure warning 6 and 2; critical
    /// keeps only what shows.
    public static func forMemory(physicalBytes: UInt64, pressure: MemoryPressureLevel) -> WarmSetBudget {
        switch pressure {
        case .critical:
            return WarmSetBudget(terminalCapacity: 0, pageCapacity: 0)
        case .warning:
            return WarmSetBudget(terminalCapacity: 6, pageCapacity: 2)
        case .normal:
            return WarmSetBudget(terminalCapacity: min(24, max(8, Int((physicalBytes / 64) / terminalCostBytes))),
                                 pageCapacity: min(16, max(minimumPages, Int((physicalBytes / 64) / pageCostBytes))))
        }
    }

    /// Measured cost of one hidden live web page, its renderer process: 55 MB for a Chromium
    /// tab, 29 MB for a WebKit tab (cmux20, macOS 27, 2026-10-22, speed-of-sound-DESIGN.md
    /// section 7). The larger one sizes the budget, so either engine fits it.
    public static let pageCostBytes: UInt64 = 56 << 20

    /// Hidden live pages every Mac keeps beyond the shown ones and their neighbors: 1/64 of
    /// memory would keep 2 on an 8 GB Mac.
    public static let minimumPages = 4

    public static func current(pressure: MemoryPressureLevel = .normal) -> WarmSetBudget {
        forMemory(physicalBytes: ProcessInfo.processInfo.physicalMemory, pressure: pressure)
    }

    public static let standard = current()
}
