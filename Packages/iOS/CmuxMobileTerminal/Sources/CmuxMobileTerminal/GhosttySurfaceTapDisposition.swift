#if canImport(UIKit)
/// Synchronous keyboard policy decided from the host's last settled artifact snapshot.
public enum GhosttySurfaceTapInputPolicy: Sendable {
    case focusImmediately
    case deferForArtifactDecision
}

/// Tells the terminal surface whether a completed tap should claim keyboard focus.
public enum GhosttySurfaceTapDisposition: Sendable {
    /// The host opened an artifact for the tapped path; terminal focus must remain unchanged.
    case openedArtifact
    /// The tap belongs to the terminal and should raise or restore its input focus.
    case focusTerminal
    /// The tap completed after its surface was dismantled or superseded, so no action remains.
    case ignored

    var shouldFocusTerminal: Bool {
        self == .focusTerminal
    }
}
#endif
