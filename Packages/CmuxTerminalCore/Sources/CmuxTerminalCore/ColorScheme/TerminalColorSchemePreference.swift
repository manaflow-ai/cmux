/// The light/dark preference that drives terminal theme selection.
///
/// This is the terminal-domain home of what was `GhosttyConfig.ColorSchemePreference`.
/// It is the value libghostty theme resolution keys off of, distinct from the
/// app's broader appearance mode (which also carries `system`/`auto`). cmux
/// resolves the app appearance mode down to this two-case preference before
/// loading terminal colors.
public enum TerminalColorSchemePreference: Hashable, Sendable {
    case light
    case dark
}
