public import Foundation

/// Resolved Ghostty configuration and drawable geometry for one scene renderer.
public struct CmxIrohTerminalSceneConfiguration: Equatable, Sendable {
    /// Validation failures caught before renderer creation.
    public enum ValidationError: Error, Equatable, Sendable {
        case zeroIdentity
        case zeroTerminalEpoch
        case zeroPresentationGeneration
        case invalidDimensions
        case invalidContentScale
        case rendererConfigTooLarge(actual: Int, maximum: Int)
    }

    /// Largest resolved Ghostty configuration accepted from the host.
    public static let maximumRendererConfigByteCount = 256 * 1_024

    public let terminalID: UUID
    public let terminalEpoch: UInt64
    public let presentationID: UUID
    public let presentationGeneration: UInt64
    public let rendererConfigRevision: UInt64
    public let width: UInt32
    public let height: UInt32
    public let contentScale: Double
    public let rendererConfig: Data

    /// Creates one validated renderer configuration envelope.
    public init(
        terminalID: UUID,
        terminalEpoch: UInt64,
        presentationID: UUID,
        presentationGeneration: UInt64,
        rendererConfigRevision: UInt64,
        width: UInt32,
        height: UInt32,
        contentScale: Double,
        rendererConfig: Data
    ) throws {
        guard terminalID != Self.zeroUUID, presentationID != Self.zeroUUID else {
            throw ValidationError.zeroIdentity
        }
        guard terminalEpoch != 0 else {
            throw ValidationError.zeroTerminalEpoch
        }
        guard presentationGeneration != 0 else {
            throw ValidationError.zeroPresentationGeneration
        }
        guard width > 0,
              height > 0,
              width <= CmxIrohTerminalSceneLaneRequest.maximumDimension,
              height <= CmxIrohTerminalSceneLaneRequest.maximumDimension,
              UInt64(width) * UInt64(height)
                <= CmxIrohTerminalSceneLaneRequest.maximumPixelCount else {
            throw ValidationError.invalidDimensions
        }
        guard contentScale.isFinite,
              contentScale > 0,
              contentScale <= CmxIrohTerminalSceneLaneRequest.maximumContentScale else {
            throw ValidationError.invalidContentScale
        }
        guard rendererConfig.count <= Self.maximumRendererConfigByteCount else {
            throw ValidationError.rendererConfigTooLarge(
                actual: rendererConfig.count,
                maximum: Self.maximumRendererConfigByteCount
            )
        }
        self.terminalID = terminalID
        self.terminalEpoch = terminalEpoch
        self.presentationID = presentationID
        self.presentationGeneration = presentationGeneration
        self.rendererConfigRevision = rendererConfigRevision
        self.width = width
        self.height = height
        self.contentScale = contentScale
        self.rendererConfig = rendererConfig
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}
