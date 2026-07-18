#if canImport(UIKit)
/// Tells the terminal surface whether a completed tap should claim keyboard focus.
public enum GhosttySurfaceTapDisposition: Sendable {
    /// The host opened an artifact for the tapped path; terminal focus must remain unchanged.
    case openedArtifact
    /// The tap belongs to the terminal and should raise or restore its input focus.
    case focusTerminal

    var shouldFocusTerminal: Bool {
        self == .focusTerminal
    }
}
#endif
