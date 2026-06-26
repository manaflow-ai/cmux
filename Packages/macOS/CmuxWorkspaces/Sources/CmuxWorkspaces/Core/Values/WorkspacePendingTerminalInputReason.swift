public import Foundation

/// Why terminal input is being queued until the surface's shell is ready.
///
/// Formerly a top-level enum in `Workspace.swift` paired with the case-less
/// `WorkspacePendingTerminalInputPolicy` namespace; the policy's timeout
/// lookup is now a property on the reason itself (one source of truth).
public enum WorkspacePendingTerminalInputReason: Sendable, Equatable {
    /// Input injected by a workspace configuration command (cmux.json).
    case configurationCommand
    /// Crash/update recovery input that must wait for the restored terminal.
    case recoveryInput

    /// How long queued input for this reason may wait for shell readiness
    /// before being dropped.
    public var timeout: TimeInterval? {
        switch self {
        case .configurationCommand:
            return 3.0
        case .recoveryInput:
            return 60.0
        }
    }
}
