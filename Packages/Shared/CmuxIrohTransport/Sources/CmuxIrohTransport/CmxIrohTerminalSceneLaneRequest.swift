public import Foundation

/// Immutable geometry and presentation identity for one semantic terminal lane.
public struct CmxIrohTerminalSceneLaneRequest: Equatable, Sendable {
    /// Validation failures caught before a scene lane can allocate renderer resources.
    public enum ValidationError: Error, Equatable, Sendable {
        case zeroPresentationID
        case zeroPresentationGeneration
        case invalidDimensions
        case invalidContentScale
    }

    /// Largest accepted physical width or height.
    public static let maximumDimension: UInt32 = 16_384

    /// Largest accepted drawable area in physical pixels.
    public static let maximumPixelCount: UInt64 = 134_217_728

    /// Largest accepted number of physical pixels per logical point.
    public static let maximumContentScale = 16.0

    /// Canonical terminal resource requested from the host.
    public let resourceID: CmxIrohResourceID

    /// Client-created identity for this view.
    public let presentationID: UUID

    /// Nonzero lifetime fence for geometry and renderer state.
    public let presentationGeneration: UInt64

    /// Drawable width in physical pixels.
    public let width: UInt32

    /// Drawable height in physical pixels.
    public let height: UInt32

    /// Number of physical pixels per logical point.
    public let contentScale: Double

    /// Creates one validated semantic terminal presentation request.
    public init(
        resourceID: CmxIrohResourceID,
        presentationID: UUID,
        presentationGeneration: UInt64,
        width: UInt32,
        height: UInt32,
        contentScale: Double
    ) throws {
        guard presentationID != Self.zeroUUID else {
            throw ValidationError.zeroPresentationID
        }
        guard presentationGeneration != 0 else {
            throw ValidationError.zeroPresentationGeneration
        }
        guard width > 0,
              height > 0,
              width <= Self.maximumDimension,
              height <= Self.maximumDimension,
              UInt64(width) * UInt64(height) <= Self.maximumPixelCount else {
            throw ValidationError.invalidDimensions
        }
        guard contentScale.isFinite,
              contentScale > 0,
              contentScale <= Self.maximumContentScale else {
            throw ValidationError.invalidContentScale
        }
        self.resourceID = resourceID
        self.presentationID = presentationID
        self.presentationGeneration = presentationGeneration
        self.width = width
        self.height = height
        self.contentScale = contentScale
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}
