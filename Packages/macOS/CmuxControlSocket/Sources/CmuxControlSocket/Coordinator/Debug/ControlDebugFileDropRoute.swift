#if DEBUG
/// The drop route for `debug.terminal.simulate_file_drop` (the package twin of
/// the legacy body's local `TerminalFileDropSimulationRoute`).
public enum ControlDebugFileDropRoute: Sendable, Equatable {
    /// Drop directly onto the terminal view (`terminal` / `direct`).
    case terminal
    /// Drop onto the pane's text destination (`text` / `text_destination` /
    /// `pane_text`, the default).
    case textDestination
}
#endif
