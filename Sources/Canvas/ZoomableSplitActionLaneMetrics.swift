import AppKit

enum ZoomableSplitActionLaneMetrics {
    static let reservedButtonWidth: CGFloat = 22
    static let spacing: CGFloat = 4
    static let leadingPadding: CGFloat = 6
    static let trailingPadding: CGFloat = 8

    static func laneWidth(buttonCount: Int) -> CGFloat {
        guard buttonCount > 0 else { return 0 }
        return leadingPadding
            + trailingPadding
            + CGFloat(buttonCount) * reservedButtonWidth
            + CGFloat(max(0, buttonCount - 1)) * spacing
    }
}
