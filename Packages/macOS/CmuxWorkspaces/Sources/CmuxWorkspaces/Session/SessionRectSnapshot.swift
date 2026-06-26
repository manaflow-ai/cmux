public import CoreGraphics

/// A persisted rectangle inside a session snapshot.
///
/// A pure leaf value carrying a rect's `x`/`y`/`width`/`height` as `Double`. The
/// on-disk wire format is owned by the app's `SessionWindowSnapshot`; encoding
/// stays byte-identical to the legacy app-target definition (default `Codable`
/// synthesis over the same stored-property set). Bridges to/from CoreGraphics via
/// `init(_:)` and `cgRect`.
public struct SessionRectSnapshot: Codable, Equatable, Sendable {
    /// The rect origin's x coordinate.
    public let x: Double
    /// The rect origin's y coordinate.
    public let y: Double
    /// The rect's width.
    public let width: Double
    /// The rect's height.
    public let height: Double

    /// Creates a rect snapshot from explicit components.
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Creates a rect snapshot from a CoreGraphics rect.
    public init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.size.width)
        self.height = Double(rect.size.height)
    }

    /// The snapshot as a CoreGraphics rect.
    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
