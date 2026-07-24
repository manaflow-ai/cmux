import AppKit

/// A guest cursor: a vector kite silhouette in the participant's color with a
/// white outline, plus a small name chip below-right of the tip. The view is
/// flipped so the pointer tip sits at the view origin; it never intercepts
/// mouse events.
final class ShareCursorPointerView: NSView {
    static let maximumBubbleTextBytes = 512

    private static let pointerSize: CGFloat = 20
    private static let unitViewBox: CGFloat = 13
    private static let chipFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
    private static let chipPadding = NSSize(width: 5, height: 2)
    private static let bubbleFont = NSFont.systemFont(ofSize: 12)
    private static let bubblePadding = NSSize(width: 9, height: 6)
    private static let bubbleMaximumTextWidth: CGFloat = 240
    private static let bubbleMaximumLines: CGFloat = 4
    private static let bubbleGap: CGFloat = 4

    private let color: NSColor
    private var name: String
    private(set) var bubbleText: String?

    init(color: NSColor, name: String) {
        self.color = color
        self.name = name
        super.init(frame: .zero)
        wantsLayer = true
        sizeToFitContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// The overlay is presentation-only; let events fall through to the pane.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setName(_ newName: String) {
        guard newName != name else { return }
        name = newName
        sizeToFitContent()
        needsDisplay = true
    }

    func setBubbleText(_ newText: String?) {
        let bounded = newText.map(Self.boundedBubbleText)
        let normalized = bounded?.isEmpty == false ? bounded : nil
        guard normalized != bubbleText else { return }
        bubbleText = normalized
        sizeToFitContent()
        needsDisplay = true
    }

    static func boundedBubbleText(_ text: String) -> String {
        guard text.utf8.count > maximumBubbleTextBytes else { return text }
        let suffix = "…"
        let budget = maximumBubbleTextBytes - suffix.utf8.count
        var end = text.startIndex
        var usedBytes = 0
        while end < text.endIndex {
            let next = text.index(after: end)
            let characterBytes = text[end..<next].utf8.count
            guard usedBytes + characterBytes <= budget else { break }
            usedBytes += characterBytes
            end = next
        }
        return String(text[..<end]) + suffix
    }

    private var chipTextSize: NSSize {
        (name as NSString).size(withAttributes: [.font: Self.chipFont])
    }

    private var chipRect: NSRect {
        let text = chipTextSize
        return NSRect(
            x: Self.pointerSize * 0.7,
            y: Self.pointerSize * 0.9 - Self.chipPadding.height,
            width: ceil(text.width) + Self.chipPadding.width * 2,
            height: ceil(text.height) + Self.chipPadding.height * 2
        )
    }

    private var bubbleTextSize: NSSize? {
        guard let bubbleText else { return nil }
        let lineHeight = ceil(
            Self.bubbleFont.ascender
                - Self.bubbleFont.descender
                + Self.bubbleFont.leading
        )
        let bounds = (bubbleText as NSString).boundingRect(
            with: NSSize(
                width: Self.bubbleMaximumTextWidth,
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: Self.bubbleFont]
        )
        return NSSize(
            width: min(
                Self.bubbleMaximumTextWidth,
                max(1, ceil(bounds.width))
            ),
            height: min(
                lineHeight * Self.bubbleMaximumLines,
                max(lineHeight, ceil(bounds.height))
            )
        )
    }

    private var bubbleRect: NSRect? {
        guard let textSize = bubbleTextSize else { return nil }
        return NSRect(
            x: Self.pointerSize * 0.7,
            y: chipRect.maxY + Self.bubbleGap,
            width: textSize.width + Self.bubblePadding.width * 2,
            height: textSize.height + Self.bubblePadding.height * 2
        )
    }

    private func sizeToFitContent() {
        let bubbleRect = bubbleRect
        setFrameSize(NSSize(
            width: max(
                Self.pointerSize,
                chipRect.maxX,
                bubbleRect?.maxX ?? 0
            ),
            height: max(chipRect.maxY, bubbleRect?.maxY ?? 0)
        ))
    }

    override func draw(_ dirtyRect: NSRect) {
        let scale = Self.pointerSize / Self.unitViewBox
        let path = Self.kitePath()
        var transform = AffineTransform.identity
        transform.scale(scale)
        path.transform(using: transform)

        NSColor.white.setStroke()
        path.lineWidth = 1.7
        path.lineJoinStyle = .round
        path.stroke()
        color.setFill()
        path.fill()

        drawNameChip()
        drawBubble()
    }

    private func drawNameChip() {
        let chipRect = chipRect
        let chip = NSBezierPath(roundedRect: chipRect, xRadius: 4, yRadius: 4)
        color.setFill()
        chip.fill()
        (name as NSString).draw(
            at: NSPoint(
                x: chipRect.minX + Self.chipPadding.width,
                y: chipRect.minY + Self.chipPadding.height
            ),
            withAttributes: [.font: Self.chipFont, .foregroundColor: NSColor.white]
        )
    }

    private func drawBubble() {
        guard let bubbleText, let bubbleRect else { return }
        let bubble = NSBezierPath(
            roundedRect: bubbleRect,
            xRadius: 9,
            yRadius: 9
        )
        color.withAlphaComponent(0.96).setFill()
        bubble.fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let textRect = bubbleRect.insetBy(
            dx: Self.bubblePadding.width,
            dy: Self.bubblePadding.height
        )
        (bubbleText as NSString).draw(
            with: textRect,
            options: [
                .usesLineFragmentOrigin,
                .usesFontLeading,
                .truncatesLastVisibleLine,
            ],
            attributes: [
                .font: Self.bubbleFont,
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph,
            ]
        )
    }

    /// The kite silhouette in a ~13-unit view box, tip at the origin.
    private static func kitePath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0.68, y: 1.83))
        path.line(to: NSPoint(x: 3.63, y: 9.78))
        path.quadCurve(to: NSPoint(x: 5.3, y: 9.66), control: NSPoint(x: 4.67, y: 12.59))
        path.line(to: NSPoint(x: 5.44, y: 9.01))
        path.quadCurve(to: NSPoint(x: 9.01, y: 5.44), control: NSPoint(x: 6.08, y: 6.08))
        path.line(to: NSPoint(x: 9.66, y: 5.3))
        path.quadCurve(to: NSPoint(x: 9.78, y: 3.63), control: NSPoint(x: 12.59, y: 4.67))
        path.line(to: NSPoint(x: 1.83, y: 0.68))
        path.quadCurve(to: NSPoint(x: 0.68, y: 1.83), control: NSPoint(x: 0, y: 0))
        path.close()
        return path
    }
}

private extension NSBezierPath {
    /// Quadratic Bezier segment expressed as the equivalent cubic.
    func quadCurve(to endPoint: NSPoint, control: NSPoint) {
        let start = currentPoint
        let control1 = NSPoint(
            x: start.x + (control.x - start.x) * 2 / 3,
            y: start.y + (control.y - start.y) * 2 / 3
        )
        let control2 = NSPoint(
            x: endPoint.x + (control.x - endPoint.x) * 2 / 3,
            y: endPoint.y + (control.y - endPoint.y) * 2 / 3
        )
        curve(to: endPoint, controlPoint1: control1, controlPoint2: control2)
    }
}
