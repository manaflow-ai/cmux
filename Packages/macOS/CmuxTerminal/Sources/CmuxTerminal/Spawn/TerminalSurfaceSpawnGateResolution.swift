import Foundation

/// The terminal package's app-supplied spawn-gate decision.
public enum TerminalSurfaceSpawnGateResolution: Sendable, Equatable {
    /// The spawn may proceed with the included final values.
    case proceed(TerminalSurfaceSpawnGrant)

    /// The spawn must not execute.
    case deny(reason: String)
}
