import CmuxTerminalBackend

/// Main-actor projection seam used by the stream coordinator and focused tests.
@MainActor
protocol TerminalBackendTopologyProjecting: AnyObject {
    func legacyTerminalPlacements() -> Set<TerminalBackendTopologyPlacement>
    func installCanonicalTopology(_ snapshot: TopologySnapshot) throws
}
