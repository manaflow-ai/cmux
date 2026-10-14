/// Whether status indicators move (`appearance.statusIndicator.animation`,
/// cx-sya4n). Static stills every indicator, draws each state as its own
/// shape and names it; Reduce Motion always gets the static look.
public nonisolated enum StatusIndicatorAnimation: String, Hashable, Sendable, CaseIterable {
    /// Spinners, the working wave and pulses run (the default).
    case animated
    /// Steady colors, a distinct shape per state, and short labels.
    case `static`
}
