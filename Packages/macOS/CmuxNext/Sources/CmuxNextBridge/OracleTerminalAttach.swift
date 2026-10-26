#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextOracle

extension TerminalAttachMachine.Phase {
    /// The `terminals` facet's attach state (p15-oracle-044): a link live, opening, gone or never made, or the
    /// terminal's process ended.
    public nonisolated var oracleAttach: OracleTerminalsFacet.Attach {
        switch self {
        case .live: .attached
        case .attaching, .reattaching: .attaching
        case .detached, .disconnected, .closed: .detached
        case .exited: .dead
        }
    }
}
#endif
