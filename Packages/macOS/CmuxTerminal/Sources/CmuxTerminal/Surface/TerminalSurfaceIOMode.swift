internal import GhosttyKit

/// Identifies who owns a terminal surface's process and terminal protocol.
public enum TerminalSurfaceIOMode: Equatable, Sendable {
    /// Ghostty owns the child process, PTY, and terminal protocol.
    case exec

    /// The embedder supplies output and accepts all writes from Ghostty,
    /// including parser-generated terminal replies.
    case manual

    /// The embedder owns the PTY and terminal protocol while Ghostty mirrors
    /// output for rendering and encodes only user input.
    case manualMirror

    var usesManualIO: Bool {
        self != .exec
    }

    var ghosttyMode: ghostty_surface_io_mode_e {
        switch self {
        case .exec:
            GHOSTTY_SURFACE_IO_EXEC
        case .manual:
            GHOSTTY_SURFACE_IO_MANUAL
        case .manualMirror:
            GHOSTTY_SURFACE_IO_MANUAL_MIRROR
        }
    }
}
