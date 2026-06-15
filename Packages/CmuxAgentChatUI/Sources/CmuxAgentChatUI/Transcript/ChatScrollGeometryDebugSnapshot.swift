#if os(iOS) && DEBUG
import SwiftUI

struct ChatScrollGeometryDebugSnapshot: Equatable {
    var contentOffset: CGPoint = .zero
    var contentSize: CGSize = .zero
    var visibleRect: CGRect = .zero
    var containerSize: CGSize = .zero
    var contentInsetTop: CGFloat = 0
    var contentInsetLeading: CGFloat = 0
    var contentInsetBottom: CGFloat = 0
    var contentInsetTrailing: CGFloat = 0
    var distanceFromBottom: CGFloat = 0

    init() {}

    init(_ geometry: ScrollGeometry) {
        contentOffset = geometry.contentOffset
        contentSize = geometry.contentSize
        visibleRect = geometry.visibleRect
        containerSize = geometry.containerSize
        contentInsetTop = geometry.contentInsets.top
        contentInsetLeading = geometry.contentInsets.leading
        contentInsetBottom = geometry.contentInsets.bottom
        contentInsetTrailing = geometry.contentInsets.trailing
        distanceFromBottom = max(0, geometry.contentSize.height - geometry.visibleRect.maxY)
    }
}
#endif
