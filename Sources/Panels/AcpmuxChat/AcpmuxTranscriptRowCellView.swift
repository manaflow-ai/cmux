import AppKit

/// A reusable transcript cell: an optional bubble or card surface plus selectable text,
/// with a timestamp that fades in on hover.
final class AcpmuxTranscriptRowCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("acpmuxChat.row")

    private let surfaceLayer = CAShapeLayer()
    private let textView = AcpmuxTranscriptTextView()
    private let timestampLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private(set) var rowID: String?
    private(set) var handlesToggle = false
    var onToggle: ((String) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        wantsLayer = true
        layer?.addSublayer(surfaceLayer)
        addSubview(textView)
        timestampLabel.alphaValue = 0
        timestampLabel.font = .systemFont(ofSize: 10.5)
        addSubview(timestampLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(rowID: String, layout: AcpmuxRowLayout, theme: AcpmuxChatTheme, hidden: Bool) {
        self.rowID = rowID
        handlesToggle = layout.isToggleable
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let pathBuilder = AcpmuxBubblePath(radius: layout.surface == .card ? 10 : 17)
        switch layout.surface {
        case .userBubble:
            surfaceLayer.fillColor = theme.userBubble.cgColor
            surfaceLayer.path = pathBuilder.path(for: layout.surfaceFrame, tail: layout.showsTail ? .trailing : nil)
        case .assistantBubble:
            surfaceLayer.fillColor = theme.assistantBubble.cgColor
            surfaceLayer.path = pathBuilder.path(for: layout.surfaceFrame, tail: layout.showsTail ? .leading : nil)
        case .card:
            surfaceLayer.fillColor = theme.surface.cgColor
            surfaceLayer.path = pathBuilder.path(for: layout.surfaceFrame, tail: nil)
        case .none, .typing:
            surfaceLayer.path = nil
        }
        surfaceLayer.frame = bounds
        CATransaction.commit()
        textView.apply(layout.text, frame: layout.textFrame)
        alphaValue = hidden ? 0 : (layout.dimmed ? 0.72 : 1)
        timestampLabel.stringValue = layout.timestamp ?? ""
        timestampLabel.textColor = theme.tertiaryText
        timestampLabel.sizeToFit()
        let stampY = layout.surfaceFrame.maxY - timestampLabel.frame.height
        if layout.surface == .userBubble {
            timestampLabel.frame.origin = CGPoint(x: max(4, layout.surfaceFrame.minX - timestampLabel.frame.width - 10), y: stampY)
        } else {
            timestampLabel.frame.origin = CGPoint(
                x: min(bounds.width - timestampLabel.frame.width - 4, layout.surfaceFrame.maxX + 10),
                y: stampY
            )
        }
        timestampLabel.isHidden = layout.timestamp == nil || (layout.surface != .userBubble && layout.surface != .assistantBubble)
    }

    override func layout() {
        super.layout()
        surfaceLayer.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            timestampLabel.animator().alphaValue = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            timestampLabel.animator().alphaValue = 0
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard handlesToggle, let rowID else {
            super.mouseDown(with: event)
            return
        }
        onToggle?(rowID)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        layer?.removeAllAnimations()
        timestampLabel.alphaValue = 0
        onToggle = nil
    }
}
