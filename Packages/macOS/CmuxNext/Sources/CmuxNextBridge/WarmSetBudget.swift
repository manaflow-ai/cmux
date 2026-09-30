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

    public init(terminalCapacity: Int, parkedWorkspaces: Int) {
        self.terminalCapacity = max(0, terminalCapacity)
        self.parkedWorkspaces = max(0, parkedWorkspaces)
    }

    /// Estimated cost of one hidden terminal surface (grid, atlas share,
    /// Metal layer backing store).
    public static let terminalCostBytes: UInt64 = 16 << 20

    /// 1/64 of physical memory for hidden terminal surfaces (4 to 24 of
    /// them) and one parked workspace per 8 GB (1 to 4). Under a pressure
    /// warning 4 surfaces and 1 workspace; critical keeps only what shows.
    public static func forMemory(physicalBytes: UInt64, pressure: MemoryPressureLevel) -> WarmSetBudget {
        switch pressure {
        case .critical:
            return WarmSetBudget(terminalCapacity: 0, parkedWorkspaces: 0)
        case .warning:
            return WarmSetBudget(terminalCapacity: 4, parkedWorkspaces: 1)
        case .normal:
            let surfaces = Int((physicalBytes / 64) / terminalCostBytes)
            let workspaces = Int(physicalBytes / (8 << 30))
            return WarmSetBudget(terminalCapacity: min(24, max(4, surfaces)), parkedWorkspaces: min(4, max(1, workspaces)))
        }
    }

    public static func current(pressure: MemoryPressureLevel = .normal) -> WarmSetBudget {
        forMemory(physicalBytes: ProcessInfo.processInfo.physicalMemory, pressure: pressure)
    }

    public static let standard = current()
}
