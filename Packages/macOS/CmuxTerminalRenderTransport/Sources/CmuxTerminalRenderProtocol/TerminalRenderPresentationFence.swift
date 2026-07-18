public import Foundation

/// The exact presentation state a Swift receiver currently permits.
public struct TerminalRenderPresentationFence: Equatable, Sendable {
    /// Expected cmuxd process lifetime.
    public let daemonInstanceID: UUID

    /// Expected renderer-worker lifetime.
    public let rendererEpoch: UInt64

    /// Expected canonical terminal identity.
    public let terminalID: UUID

    /// Expected canonical terminal-runtime lifetime.
    public let terminalEpoch: UInt64

    /// Oldest terminal mutation that may be displayed.
    public let minimumTerminalSequence: UInt64

    /// Expected client-local presentation identity.
    public let presentationID: UUID

    /// Expected presentation lifetime.
    public let presentationGeneration: UInt64

    /// Expected pixel width.
    public let width: UInt32

    /// Expected pixel height.
    public let height: UInt32

    /// Expected IOSurface pixel format.
    public let pixelFormat: TerminalRenderPixelFormat

    /// Expected frame color space.
    public let colorSpace: TerminalRenderColorSpace

    /// Completion mechanism accepted for this presentation generation.
    public let completionRequirement: TerminalRenderCompletionRequirement

    /// Creates a presentation fence with bounded dimensions and validated completion requirements.
    ///
    /// - Parameters:
    ///   - daemonInstanceID: Expected cmuxd process lifetime.
    ///   - rendererEpoch: Expected renderer-worker lifetime.
    ///   - terminalID: Expected canonical terminal identity.
    ///   - terminalEpoch: Expected canonical terminal-runtime lifetime.
    ///   - minimumTerminalSequence: Oldest canonical mutation that may be displayed.
    ///   - presentationID: Expected client-local presentation identity.
    ///   - presentationGeneration: Expected render-affecting presentation lifetime.
    ///   - width: Expected IOSurface width in pixels.
    ///   - height: Expected IOSurface height in pixels.
    ///   - pixelFormat: Expected IOSurface pixel layout.
    ///   - colorSpace: Expected layer color-space semantics.
    ///   - completionRequirement: Accepted producer-completion or shared-event synchronization.
    /// - Throws: ``TerminalRenderFrameProtocolError`` when dimensions or a shared-event value are invalid.
    public init(
        daemonInstanceID: UUID,
        rendererEpoch: UInt64,
        terminalID: UUID,
        terminalEpoch: UInt64,
        minimumTerminalSequence: UInt64,
        presentationID: UUID,
        presentationGeneration: UInt64,
        width: UInt32,
        height: UInt32,
        pixelFormat: TerminalRenderPixelFormat,
        colorSpace: TerminalRenderColorSpace,
        completionRequirement: TerminalRenderCompletionRequirement
    ) throws {
        let completionFence: TerminalRenderCompletionFence
        switch completionRequirement {
        case .producerCompleted:
            completionFence = .producerCompleted
        case let .sharedEvent(eventID, minimumValue):
            guard minimumValue > 0 else {
                throw TerminalRenderFrameProtocolError.invalidCompletionFence
            }
            completionFence = .sharedEvent(eventID: eventID, value: minimumValue)
        }
        _ = try TerminalRenderFrameMetadata(
            daemonInstanceID: daemonInstanceID,
            rendererEpoch: rendererEpoch,
            terminalID: terminalID,
            terminalEpoch: terminalEpoch,
            terminalSequence: minimumTerminalSequence,
            presentationID: presentationID,
            presentationGeneration: presentationGeneration,
            frameSequence: 0,
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            colorSpace: colorSpace,
            completionFence: completionFence,
            damageBounds: nil
        )
        self.daemonInstanceID = daemonInstanceID
        self.rendererEpoch = rendererEpoch
        self.terminalID = terminalID
        self.terminalEpoch = terminalEpoch
        self.minimumTerminalSequence = minimumTerminalSequence
        self.presentationID = presentationID
        self.presentationGeneration = presentationGeneration
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.colorSpace = colorSpace
        self.completionRequirement = completionRequirement
    }
}
