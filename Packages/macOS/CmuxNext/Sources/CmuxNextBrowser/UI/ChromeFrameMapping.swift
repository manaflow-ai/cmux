import CoreGraphics

/// Maps top-down, leading-first rects into a view's coordinates.
nonisolated struct ChromeFrameMapping: Equatable, Sendable {
    var size: CGSize
    var isFlipped: Bool
    var rightToLeft: Bool

    func map(_ rect: CGRect) -> CGRect {
        let x = rightToLeft ? size.width - rect.maxX : rect.minX
        let y = isFlipped ? rect.minY : size.height - rect.maxY
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }
}

/// Equal buttons in a line from the leading edge (the toolbar buttons).
nonisolated struct ButtonLineLayout: Equatable, Sendable {
    var frames: [CGRect]
    var width: CGFloat

    init(count: Int, button: CGFloat, spacing: CGFloat, height: CGFloat) {
        let count = max(0, count)
        frames = (0..<count).map { index in
            CGRect(x: CGFloat(index) * (button + spacing), y: (height - button) / 2, width: button, height: button)
        }
        width = count == 0 ? 0 : CGFloat(count) * button + CGFloat(count - 1) * spacing
    }
}
