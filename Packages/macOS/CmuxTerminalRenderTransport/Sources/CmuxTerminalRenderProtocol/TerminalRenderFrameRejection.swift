/// Why a decoded frame cannot be displayed in the current presentation.
public enum TerminalRenderFrameRejection: Equatable, Sendable {
    /// The frame belongs to another cmuxd lifetime.
    case daemonInstanceMismatch

    /// The frame belongs to another renderer-worker lifetime.
    case rendererEpochMismatch

    /// The frame belongs to another canonical terminal.
    case terminalIdentityMismatch

    /// The frame belongs to another canonical terminal-runtime lifetime.
    case terminalEpochMismatch

    /// The frame represents an older canonical terminal mutation.
    case staleTerminalSequence

    /// The frame belongs to another client-local presentation.
    case presentationIdentityMismatch

    /// The frame belongs to another presentation lifetime.
    case presentationGenerationMismatch

    /// The frame metadata dimensions do not match the current layer target.
    case dimensionsMismatch

    /// The frame pixel format does not match the current IOSurface pool.
    case pixelFormatMismatch

    /// The frame color space does not match the current layer target.
    case colorSpaceMismatch

    /// The frame and presentation use different GPU-completion mechanisms.
    case completionModeMismatch

    /// The frame refers to another out-of-band shared Metal event.
    case completionFenceIdentityMismatch

    /// The frame's shared-event value is older than the required or accepted value.
    case staleCompletionFence

    /// The frame sequence is duplicate or older within its generation.
    case staleFrameSequence
}
