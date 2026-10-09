import CmuxMobileWire

/// A rectangle in target pixels (top-left origin).
public struct DesktopRect: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The whole target.
    public init(width: Int, height: Int) {
        self.init(x: 0, y: 0, width: width, height: height)
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    var jsonMembers: [String: JSONValue] {
        ["x": .int(Int64(x)), "y": .int(Int64(y)), "width": .int(Int64(width)), "height": .int(Int64(height))]
    }
}
