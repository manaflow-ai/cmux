public import CmuxNextCompat

/// How much hidden content stays warm (architecture.md section 4): the one
/// memory budget of hidden GPU surfaces. A window keeps every workspace it
/// showed mounted (tree, panes, strips; no budget), and its hidden terminal
/// surfaces, in the shown workspace's other tabs and in parked workspaces
/// alike, are kept in one LRU of `terminalCapacity` (`SurfaceLedger`); an
/// evicted one re-attaches with a daemon replay when its pane shows again.
/// Sized by the app's `SubsystemBudget` and shrunk under memory pressure.
public struct WarmSetBudget: Hashable, Sendable {
    /// Hidden terminal surfaces kept beyond the visible ones (LRU).
    public var terminalCapacity: Int

    public init(terminalCapacity: Int) {
        self.terminalCapacity = max(0, terminalCapacity)
    }

    /// The most hidden surfaces kept at a pressure warning, with or without the GPU release.
    public static let warningCapacity = 6

    /// The warm set at `pressure`, from `normal`, its capacity at normal pressure
    /// (`SubsystemBudget.warmTerminalSurfaces`: larger where hidden surfaces let their GPU memory go).
    /// A pressure warning keeps at most ``warningCapacity``; critical keeps only what shows. Chrome's
    /// `FrameEvictionManager` (`components/viz/client/frame_eviction_manager.cc`) also culls its LRU of
    /// hidden frames under pressure and keeps none at critical.
    public static func at(_ pressure: MemoryPressureLevel, normal: Int) -> WarmSetBudget {
        switch pressure {
        case .critical:
            WarmSetBudget(terminalCapacity: 0)
        case .warning:
            WarmSetBudget(terminalCapacity: min(warningCapacity, normal))
        case .normal:
            WarmSetBudget(terminalCapacity: normal)
        }
    }

    /// Before the app applies its budget (`AppServices.startHibernation`): the smallest warm set a Mac
    /// without the GPU release had.
    public static let standard = WarmSetBudget(terminalCapacity: 8)
}
