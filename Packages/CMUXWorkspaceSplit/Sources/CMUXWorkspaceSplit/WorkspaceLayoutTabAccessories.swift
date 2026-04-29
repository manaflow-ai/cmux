import AppKit
import SwiftUI

@MainActor
final class WorkspaceLayoutHoverButton: NSControl {
    var hoverTrackingArea: NSTrackingArea?
    let iconView = NSImageView(frame: .zero)
    var onHoverChanged: ((Bool) -> Void)?
    var onPressedChanged: ((Bool) -> Void)?
    var rendersVisuals = true {
        didSet {
            if !rendersVisuals {
                layer?.backgroundColor = NSColor.clear.cgColor
            }
            needsLayout = true
            needsDisplay = true
        }
    }
    var drawsCloseGlyph = false {
        didSet {
            iconView.isHidden = drawsCloseGlyph
            needsLayout = true
            needsDisplay = true
        }
    }
    var iconImage: NSImage? {
        didSet {
            iconView.image = iconImage
            needsLayout = true
            needsDisplay = true
        }
    }
    var iconTintColor: NSColor? {
        didSet {
            iconView.contentTintColor = iconTintColor
            needsDisplay = true
        }
    }
    var iconSize: CGFloat = TabBarMetrics.closeIconSize {
        didSet {
            needsLayout = true
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        iconView.imageScaling = .scaleProportionallyDown
        iconView.imageAlignment = .alignCenter
        addSubview(iconView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        guard rendersVisuals else {
            iconView.frame = .zero
            return
        }
        guard !drawsCloseGlyph else {
            iconView.frame = .zero
            return
        }
        let iconFrame = CGRect(
            x: (bounds.width - iconSize) / 2,
            y: (bounds.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )
        iconView.frame = iconFrame
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard rendersVisuals, drawsCloseGlyph else { return }

        let strokeWidth = max(1.35, iconSize * 0.15)
        let maxGlyphDimension = min(bounds.width, bounds.height, iconSize)
        let armLength = max(0, min(iconSize * 0.325, (maxGlyphDimension - strokeWidth) / 2 - 0.35))
#if DEBUG
        let closeGlyphDX = WorkspaceLayoutTabChromeDebugTuning.current.closeGlyphDX
        let closeGlyphDY = WorkspaceLayoutTabChromeDebugTuning.current.closeGlyphDY
#else
        let closeGlyphDX: CGFloat = 0
        let closeGlyphDY: CGFloat = 0
#endif
        let center = CGPoint(x: bounds.midX + closeGlyphDX, y: bounds.midY + closeGlyphDY)
        let path = NSBezierPath()
        path.lineWidth = strokeWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: CGPoint(x: center.x - armLength, y: center.y - armLength))
        path.line(to: CGPoint(x: center.x + armLength, y: center.y + armLength))
        path.move(to: CGPoint(x: center.x - armLength, y: center.y + armLength))
        path.line(to: CGPoint(x: center.x + armLength, y: center.y - armLength))
        (iconTintColor ?? .labelColor).setStroke()
        path.stroke()
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let next = NSTrackingArea(
            rect: .zero,
            options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        hoverTrackingArea = next
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        onPressedChanged?(true)
        window?.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: NSEvent.foreverDuration,
            mode: .eventTracking
        ) { [weak self] nextEvent, stop in
            guard let self, let nextEvent else {
                stop.pointee = true
                return
            }
            let location = self.convert(nextEvent.locationInWindow, from: nil)
            let isInside = self.bounds.contains(location)
            switch nextEvent.type {
            case .leftMouseDragged:
                self.onPressedChanged?(isInside)
            case .leftMouseUp:
                self.onPressedChanged?(false)
                if isInside, let action = self.action {
                    _ = NSApp.sendAction(action, to: self.target, from: self)
                }
                stop.pointee = true
            default:
                break
            }
        }
    }
}

final class WorkspaceLayoutZeroPaddingTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        rect
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        rect
    }

    override func cellSize(forBounds rect: NSRect) -> NSSize {
        let size = super.cellSize(forBounds: rect)
        return NSSize(width: max(0, size.width - 4), height: size.height)
    }
}

@MainActor
struct WorkspaceLayoutPaneTabShortcutHintPill: View {
    let text: String
    let fontSize: CGFloat
    let textColor: NSColor

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(Color(nsColor: textColor))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(WorkspaceLayoutShortcutHintPillBackground())
    }
}

final class WorkspaceLayoutShortcutHintPillView: NSHostingView<WorkspaceLayoutPaneTabShortcutHintPill> {

    required init(rootView: WorkspaceLayoutPaneTabShortcutHintPill) {
        super.init(rootView: rootView)
        translatesAutoresizingMaskIntoConstraints = false
    }

    convenience init(frame frameRect: NSRect) {
        self.init(
            rootView: WorkspaceLayoutPaneTabShortcutHintPill(
                text: "",
                fontSize: 9,
                textColor: .labelColor
            )
        )
        frame = frameRect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(text: String, fontSize: CGFloat, textColor: NSColor) {
        rootView = WorkspaceLayoutPaneTabShortcutHintPill(
            text: text,
            fontSize: fontSize,
            textColor: textColor
        )
        invalidateIntrinsicContentSize()
    }

    func applyAppearance() {}
}
