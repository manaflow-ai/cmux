public import CmuxTerminalRenderProtocol

/// Why a received Mach message did not become a presentable frame.
public enum TerminalRenderFrameDropReason: Equatable, Sendable {
    /// The fixed-width Mach message shape was malformed.
    case malformedMachMessage

    /// The message's unguessable per-worker capability did not match.
    case capabilityMismatch

    /// The kernel audit trailer did not match the expected renderer PID and UID.
    case peerIdentityMismatch

    /// The metadata record failed fixed-width decoding or bounds checks.
    case malformedMetadata(TerminalRenderFrameProtocolError)

    /// The metadata failed current presentation or latest-frame fences.
    case stale(TerminalRenderFrameRejection)

    /// The transferred Mach right could not be imported as an IOSurface.
    case surfaceImportFailed

    /// The imported IOSurface descriptor disagreed with authenticated metadata.
    case surfaceDescriptorMismatch
}
