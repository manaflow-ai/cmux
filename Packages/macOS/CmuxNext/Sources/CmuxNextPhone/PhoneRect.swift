/// A rectangle on the phone screen in device points, top-left origin (the
/// frame of an accessibility element; taps use the same space).
public struct PhoneRect: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The point a tap on this element uses.
    public var center: PhonePoint { PhonePoint(x: x + width / 2, y: y + height / 2) }
}
