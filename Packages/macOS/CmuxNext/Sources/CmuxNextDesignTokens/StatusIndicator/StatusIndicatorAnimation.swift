/// Whether status indicators move (`appearance.statusIndicator.animation`,
/// cx-sya4n). Static stills every indicator and draws each state as its own
/// still shape; Reduce Motion always gets the static look.
public nonisolated enum StatusIndicatorAnimation: String, Hashable, Sendable, CaseIterable {
    /// Spinners, the working wave and pulses run (the default).
    case animated
    /// Steady colors and a still shape per state.
    case `static`
}
