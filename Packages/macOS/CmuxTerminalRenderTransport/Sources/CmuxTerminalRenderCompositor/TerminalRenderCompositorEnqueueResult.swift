public import CmuxTerminalRenderProtocol

/// Result of handing one authenticated frame to the final Metal compositor.
public enum TerminalRenderCompositorEnqueueResult: Equatable, Sendable {
    /// A single full-surface GPU blit was committed immediately.
    case submitted

    /// Another blit is in flight; this frame replaced the pending frame.
    case coalesced

    /// No CAMetalDrawable was available; this remains the sole pending frame.
    case drawableUnavailable

    /// Metadata disagreed with the view's exact presentation fence.
    case rejected(TerminalRenderFrameRejection)

    /// The IOSurface could not be imported as the expected Metal texture.
    case invalidSurface

    /// The host has no Metal device or command queue.
    case metalUnavailable
}
