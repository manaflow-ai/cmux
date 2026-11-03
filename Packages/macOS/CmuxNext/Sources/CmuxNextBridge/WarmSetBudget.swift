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

    /// Cost of one warm hidden terminal in the app's footprint, with a margin. Measured 2026-11-03 on cmux24 (W1
    /// HEAVY 3 x 4 panes of a 1728 x 867 pt window at 1x, bench build): 4.6 MB a warm pane with a light screen, 5.5 MB
    /// with 3000 lines of scrollback, about 0 once evicted. On a 2x display the drawables are 4 times larger, so 20 MB
    /// covers a pane on a 2x display; a full-window terminal there measured 32 MB (2026-11-02), so a session of large
    /// panes gets fewer warm terminals than its byte share before memory pressure shrinks the set. A warm hidden
    /// terminal that prints still costs app CPU while hidden (about 1% each at 20 lines/s, SF-5).
    public static let terminalCostBytes: UInt64 = 20 << 20

    /// The most hidden terminals kept warm whatever the memory (the ledger's work per switch is O(warm)).
    public static let maxTerminals = 64

    /// 1/32 of physical memory for hidden terminals, as Chrome sizes its renderer process limit from physical memory:
    /// a switch among the visible panes of the last 2 to 3 workspaces makes no terminal session (16 GB: 25, 24 GB: 38,
    /// 32 GB: 51; at least 8, at most ``maxTerminals``). SWITCH FRAMES (STATUS 8158): with 8 warm terminals each switch
    /// between 12-pane workspaces made 12 sessions again, about 16 ms each on the main thread, and showed empty panes
    /// for about 220 ms. Under a pressure warning 6; critical keeps only what shows.
    public static func forMemory(physicalBytes: UInt64, pressure: MemoryPressureLevel) -> WarmSetBudget {
        switch pressure {
        case .critical:
            return WarmSetBudget(terminalCapacity: 0)
        case .warning:
            return WarmSetBudget(terminalCapacity: 6)
        case .normal:
            return WarmSetBudget(terminalCapacity: min(maxTerminals, max(8, Int((physicalBytes / 32) / terminalCostBytes))))
        }
    }

    public static func current(pressure: MemoryPressureLevel = .normal) -> WarmSetBudget {
        forMemory(physicalBytes: ProcessInfo.processInfo.physicalMemory, pressure: pressure)
    }

    public static let standard = current()
}
