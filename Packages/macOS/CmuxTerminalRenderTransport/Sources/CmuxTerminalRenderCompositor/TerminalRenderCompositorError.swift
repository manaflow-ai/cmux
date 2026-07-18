/// Fatal construction failures for the host's intentionally small GPU path.
public enum TerminalRenderCompositorError: Error, Equatable, Sendable {
    /// Metal is unavailable on this Mac.
    case metalDeviceUnavailable

    /// Metal could not create the one command queue used for blits.
    case commandQueueUnavailable
}
