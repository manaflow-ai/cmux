public import Foundation

/// Fixed-width provenance and presentation fences for one IOSurface frame.
public struct TerminalRenderFrameMetadata: Equatable, Sendable {
    /// Identity of the cmuxd process lifetime that produced the scene.
    public let daemonInstanceID: UUID

    /// Identity of the disposable renderer-worker lifetime.
    public let rendererEpoch: UInt64

    /// Stable canonical terminal identity.
    public let terminalID: UUID

    /// Canonical terminal-runtime lifetime.
    public let terminalEpoch: UInt64

    /// Canonical terminal mutation represented by this frame.
    public let terminalSequence: UInt64

    /// Client-local terminal presentation identity.
    public let presentationID: UUID

    /// Presentation lifetime for size, scale, theme, and IOSurface-pool changes.
    public let presentationGeneration: UInt64

    /// Monotonic frame identity within one presentation generation.
    public let frameSequence: UInt64

    /// IOSurface width in pixels.
    public let width: UInt32

    /// IOSurface height in pixels.
    public let height: UInt32

    /// IOSurface pixel layout.
    public let pixelFormat: TerminalRenderPixelFormat

    /// Color-space semantics used to render the pixels.
    public let colorSpace: TerminalRenderColorSpace

    /// Proof that the renderer completed writing this frame.
    public let completionFence: TerminalRenderCompletionFence

    /// Optional bounding rectangle of changed pixels; `nil` means full-frame damage.
    public let damageBounds: TerminalRenderDamageBounds?

    /// Creates validated frame metadata.
    ///
    /// - Parameters:
    ///   - daemonInstanceID: Identity of the producing cmuxd lifetime.
    ///   - rendererEpoch: Identity of the renderer-worker lifetime.
    ///   - terminalID: Stable canonical terminal identity.
    ///   - terminalEpoch: Canonical terminal-runtime lifetime.
    ///   - terminalSequence: Canonical terminal mutation represented by the frame.
    ///   - presentationID: Client-local presentation identity.
    ///   - presentationGeneration: Presentation lifetime for render-affecting state.
    ///   - frameSequence: Frame order within the presentation generation.
    ///   - width: IOSurface width in pixels.
    ///   - height: IOSurface height in pixels.
    ///   - pixelFormat: IOSurface pixel layout.
    ///   - colorSpace: Color-space semantics.
    ///   - completionFence: Producer-completed or shared-event synchronization.
    ///   - damageBounds: Optional changed-pixel bounds.
    /// - Throws: ``TerminalRenderFrameProtocolError`` when dimensions or damage are invalid.
    public init(
        daemonInstanceID: UUID,
        rendererEpoch: UInt64,
        terminalID: UUID,
        terminalEpoch: UInt64,
        terminalSequence: UInt64,
        presentationID: UUID,
        presentationGeneration: UInt64,
        frameSequence: UInt64,
        width: UInt32,
        height: UInt32,
        pixelFormat: TerminalRenderPixelFormat,
        colorSpace: TerminalRenderColorSpace,
        completionFence: TerminalRenderCompletionFence,
        damageBounds: TerminalRenderDamageBounds?
    ) throws {
        guard width > 0,
              height > 0,
              width <= TerminalRenderFrameProtocol.maximumDimension,
              height <= TerminalRenderFrameProtocol.maximumDimension,
              UInt64(width) * UInt64(height) <= TerminalRenderFrameProtocol.maximumPixelCount else {
            throw TerminalRenderFrameProtocolError.invalidDimensions
        }
        if let damageBounds, !damageBounds.isContained(frameWidth: width, frameHeight: height) {
            throw TerminalRenderFrameProtocolError.invalidDamageBounds
        }
        if case let .sharedEvent(_, value) = completionFence, value == 0 {
            throw TerminalRenderFrameProtocolError.invalidCompletionFence
        }
        self.daemonInstanceID = daemonInstanceID
        self.rendererEpoch = rendererEpoch
        self.terminalID = terminalID
        self.terminalEpoch = terminalEpoch
        self.terminalSequence = terminalSequence
        self.presentationID = presentationID
        self.presentationGeneration = presentationGeneration
        self.frameSequence = frameSequence
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.colorSpace = colorSpace
        self.completionFence = completionFence
        self.damageBounds = damageBounds
    }
}
