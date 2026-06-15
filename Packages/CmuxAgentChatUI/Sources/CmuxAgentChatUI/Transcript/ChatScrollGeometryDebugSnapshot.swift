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

    func differsMeaningfully(from other: ChatScrollGeometryDebugSnapshot) -> Bool {
        abs(contentOffset.y - other.contentOffset.y) >= 8
            || abs(contentSize.height - other.contentSize.height) >= 1
            || abs(visibleRect.maxY - other.visibleRect.maxY) >= 1
            || abs(visibleRect.height - other.visibleRect.height) >= 1
            || abs(containerSize.height - other.containerSize.height) >= 1
            || abs(contentInsetBottom - other.contentInsetBottom) >= 1
            || abs(distanceFromBottom - other.distanceFromBottom) >= 1
    }

    func debugLogLine(isAtBottom: Bool) -> String {
        "chat.scrollGeometry atBottom=\(isAtBottom ? 1 : 0) distance=\(format(distanceFromBottom)) offset=\(format(contentOffset)) visible=\(format(visibleRect)) content=\(format(contentSize)) container=\(format(containerSize)) insets=(\(format(contentInsetTop)),\(format(contentInsetLeading)),\(format(contentInsetBottom)),\(format(contentInsetTrailing)))"
    }

    private func format(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }

    private func format(_ point: CGPoint) -> String {
        "(\(format(point.x)),\(format(point.y)))"
    }

    private func format(_ size: CGSize) -> String {
        "(\(format(size.width)),\(format(size.height)))"
    }

    private func format(_ rect: CGRect) -> String {
        "(\(format(rect.minX)),\(format(rect.minY)),\(format(rect.width)),\(format(rect.height)))"
    }
}
#endif
