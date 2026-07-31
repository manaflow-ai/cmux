import CoreGraphics

struct PaneMapToolbarMetrics: Equatable {
    static let refreshWidth: CGFloat = 44
    static let doneWidth: CGFloat = 58
    static let spacing: CGFloat = 0
    static let height: CGFloat = 44

    static var trailingClusterWidth: CGFloat {
        refreshWidth + spacing + doneWidth
    }
}
