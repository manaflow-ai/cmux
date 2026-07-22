public import CoreGraphics

/// An exact logical viewport requested for a browser surface.
public struct BrowserViewport: Equatable, Sendable {
    /// Smallest supported viewport dimension in CSS pixels.
    public static let minimumDimension = 1

    /// Largest supported viewport dimension in CSS pixels.
    public static let maximumDimension = 4_096

    /// Logical viewport width in CSS pixels.
    public let width: Int

    /// Logical viewport height in CSS pixels.
    public let height: Int

    /// Creates a viewport when both dimensions fit the supported range.
    ///
    /// - Parameters:
    ///   - width: Logical width in CSS pixels.
    ///   - height: Logical height in CSS pixels.
    public init?(width: Int, height: Int) {
        guard Self.minimumDimension...Self.maximumDimension ~= width,
              Self.minimumDimension...Self.maximumDimension ~= height else {
            return nil
        }
        self.width = width
        self.height = height
    }

    /// The viewport as a Core Graphics size.
    public var size: CGSize {
        CGSize(width: width, height: height)
    }
}
