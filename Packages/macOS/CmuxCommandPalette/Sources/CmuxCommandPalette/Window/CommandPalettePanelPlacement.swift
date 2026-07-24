public import CoreGraphics

/// Positions a command-palette panel near the top-center of its owning window
/// while keeping the complete panel inside the active screen's visible frame.
public struct CommandPalettePanelPlacement: Sendable, Equatable {
    public let ownerFrame: CGRect
    public let visibleFrame: CGRect
    public let contentSize: CGSize
    public let topInset: CGFloat
    public let screenInset: CGFloat

    public init(
        ownerFrame: CGRect,
        visibleFrame: CGRect,
        contentSize: CGSize,
        topInset: CGFloat = 40,
        screenInset: CGFloat = 12
    ) {
        self.ownerFrame = ownerFrame
        self.visibleFrame = visibleFrame
        self.contentSize = contentSize
        self.topInset = topInset
        self.screenInset = screenInset
    }

    public var frame: CGRect {
        let availableWidth = max(1, visibleFrame.width - screenInset * 2)
        let availableHeight = max(1, visibleFrame.height - screenInset * 2)
        let width = min(max(1, contentSize.width), availableWidth)
        let height = min(max(1, contentSize.height), availableHeight)

        let minimumX = visibleFrame.minX + screenInset
        let maximumX = visibleFrame.maxX - screenInset - width
        let preferredX = ownerFrame.midX - width / 2
        let x = min(max(preferredX, minimumX), maximumX)

        let minimumTop = visibleFrame.minY + screenInset + height
        let maximumTop = visibleFrame.maxY - screenInset
        let preferredTop = ownerFrame.maxY - topInset
        let top = min(max(preferredTop, minimumTop), maximumTop)

        return CGRect(x: x, y: top - height, width: width, height: height)
    }
}
