public import CoreGraphics

public nonisolated extension CGRect {
    /// The row crop (viewBox 2.5 2.5 19 19): the live area fills the row
    /// height; strokes past it overflow and are not clipped.
    static let iconRowCrop = CGRect(x: 2.5, y: 2.5, width: 19, height: 19)
}
