import CoreGraphics
import Foundation

public struct CodexTrajectoryInsets: Codable, Hashable, Sendable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat

    public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static let zero = CodexTrajectoryInsets()
}

public extension CGRect {
    func inset(by insets: CodexTrajectoryInsets) -> CGRect {
        CGRect(
            x: minX + insets.left,
            y: minY + insets.bottom,
            width: max(0, width - insets.left - insets.right),
            height: max(0, height - insets.top - insets.bottom)
        )
    }
}
