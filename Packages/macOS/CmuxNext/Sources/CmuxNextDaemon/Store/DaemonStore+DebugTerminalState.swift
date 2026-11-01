#if DEBUG
extension DaemonStore {
    /// Captures of an update handoff (`debug.terminal_state`): sets the
    /// `terminal_state` of the live terminal tab on `surface` (every live
    /// terminal tab when nil), as the daemon's tab push does while a new
    /// daemon adopts their hosts. Returns the surfaces it set. The next real
    /// push for a tab puts back the daemon's own state.
    @discardableResult
    public func debugSetTerminalState(_ state: TerminalTabState?, surface: SurfaceID? = nil) -> [SurfaceID] {
        let tabs = surface.map { tab(surface: $0).map { [$0] } ?? [] } ?? Array(tabsBySurface.values)
        var set: [SurfaceID] = []
        for tab in tabs where tab.kind == .pty && !tab.dead {
            tab.terminalState = state
            set.append(tab.surface)
        }
        return set
    }
}
#endif
