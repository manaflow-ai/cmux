import CoreGraphics
import Testing
@testable import CmuxNextRemoteView

private func == (lhs: (x: Int32, y: Int32), rhs: (Int32, Int32)) -> Bool {
    lhs.x == rhs.0 && lhs.y == rhs.1
}
