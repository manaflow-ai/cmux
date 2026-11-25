#if !canImport(CoreGraphics)
import Foundation

/// CoreGraphics' `CGVector` for builds without CoreGraphics (the Linux CI
/// package jobs). swift-corelibs-foundation has CGPoint, CGSize and CGRect but
/// no CGVector; this copies the members this target uses. Apple builds use
/// the CoreGraphics type and never compile this.
public struct CGVector: Equatable, Hashable, Sendable {
    public var dx: CGFloat
    public var dy: CGFloat

    public init(dx: CGFloat, dy: CGFloat) {
        self.dx = dx
        self.dy = dy
    }

    public init(dx: Double, dy: Double) {
        self.dx = CGFloat(dx)
        self.dy = CGFloat(dy)
    }

    public init(dx: Int, dy: Int) {
        self.dx = CGFloat(dx)
        self.dy = CGFloat(dy)
    }

    public static let zero = CGVector(dx: CGFloat(0), dy: CGFloat(0))
}
#endif
