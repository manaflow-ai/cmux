import SwiftUI

/// Corner placement and drag snapping for ``WebViewFindBar``.
enum WebViewFindBarCorner {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var alignment: Alignment {
        switch self {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }

    func centerPosition(in containerSize: CGSize, barSize: CGSize, padding: CGFloat) -> CGPoint {
        let halfWidth = barSize.width / 2 + padding
        let halfHeight = barSize.height / 2 + padding
        switch self {
        case .topLeft: CGPoint(x: halfWidth, y: halfHeight)
        case .topRight: CGPoint(x: containerSize.width - halfWidth, y: halfHeight)
        case .bottomLeft: CGPoint(x: halfWidth, y: containerSize.height - halfHeight)
        case .bottomRight: CGPoint(x: containerSize.width - halfWidth, y: containerSize.height - halfHeight)
        }
    }

    static func closest(to point: CGPoint, in containerSize: CGSize) -> WebViewFindBarCorner {
        if point.x < containerSize.width / 2 {
            return point.y < containerSize.height / 2 ? .topLeft : .bottomLeft
        }
        return point.y < containerSize.height / 2 ? .topRight : .bottomRight
    }
}
