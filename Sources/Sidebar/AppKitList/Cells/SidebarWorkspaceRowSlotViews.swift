import AppKit
import CmuxFoundation
import CmuxSidebar

/// Leaf AppKit views for the pure-AppKit workspace row: unread badge,
/// pull-request status icons, progress bar. Each is configured with values
/// only and draws without Auto Layout.

extension NSTextField {
    /// Unconstrained text measurement for manual layout. Never use
    /// `intrinsicContentSize` to size these labels: on a truncating
    /// single-line field it caps at the CURRENT frame width, so a pooled
    /// view laid out narrow once (they start at zero width) reports — and
    /// keeps — the truncated width no matter how much space the row has.
    /// That is exactly the "PR #4  o…" bug.
    var sidebarNaturalCellSize: NSSize {
        cell?.cellSize(forBounds: NSRect(
            x: 0, y: 0,
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )) ?? .zero
    }
}

/// Circle unread-count badge (parity with SidebarWorkspaceUnreadBadge).
/// Draws the count directly so the glyph is optically centered — NSTextField
/// intrinsic sizing carries asymmetric insets that shift small digits.
@MainActor
final class SidebarRowUnreadBadgeView: NSView {
    private var text: NSString = ""
    private var textAttributes: [NSAttributedString.Key: Any] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(count: Int, fillColor: NSColor, textColor: NSColor, font: NSFont) {
        text = NSString(string: "\(count)")
        textAttributes = [.font: font, .foregroundColor: textColor]
        layer?.backgroundColor = fillColor.cgColor
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard text.length > 0, let font = textAttributes[.font] as? NSFont else { return }
        let size = text.size(withAttributes: textAttributes)
        // Center on the digit's cap-height band, not the full line box, so
        // single digits sit optically centered in the circle.
        let capCenterOffset = (font.ascender + font.descender) / 2
        let y = bounds.midY - size.height / 2 + (size.height / 2 - font.ascender + capCenterOffset)
        text.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: y),
            withAttributes: textAttributes
        )
    }
}

/// Pull-request status icon (custom vector open/merged glyphs, SF closed).
/// Ports PullRequestOpenIcon / PullRequestMergedIcon exactly: 13x13 design
/// space, 1.2 stroke, 3.0 node circles, scaled by fontScale.
@MainActor
final class SidebarRowPullRequestIconView: NSView {
    private var status: SidebarPullRequestStatus = .open
    private var color: NSColor = .secondaryLabelColor
    private var fontScale: CGFloat = 1

    override var isFlipped: Bool { true }

    func configure(status: SidebarPullRequestStatus, color: NSColor, fontScale: CGFloat) {
        self.status = status
        self.color = color
        self.fontScale = fontScale
        needsDisplay = true
    }

    static func size(status: SidebarPullRequestStatus, fontScale: CGFloat) -> NSSize {
        switch status {
        case .closed:
            return NSSize(width: 12 * fontScale, height: 12 * fontScale)
        default:
            return NSSize(width: 13 * fontScale, height: 13 * fontScale)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        color.setStroke()

        if status == .closed {
            let image = RenderableSystemSymbol.configuredAppKitImage(
                systemName: "xmark.circle",
                pointSize: 7 * fontScale,
                weight: nil
            )
            if let image {
                let rect = NSRect(
                    x: (bounds.width - image.size.width) / 2,
                    y: (bounds.height - image.size.height) / 2,
                    width: image.size.width,
                    height: image.size.height
                )
                // Tint inside the image first: .sourceAtop against the view's
                // transparent backing draws nothing (no destination pixels).
                let tinted = NSImage(size: image.size, flipped: false) { [color] drawRect in
                    image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
                    color.set()
                    drawRect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            }
            return
        }

        context.saveGState()
        context.scaleBy(x: fontScale, y: fontScale)
        let path = NSBezierPath()
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        func node(_ x: CGFloat, _ y: CGFloat) {
            let d: CGFloat = 3.0
            let nodePath = NSBezierPath(ovalIn: NSRect(x: x - d / 2, y: y - d / 2, width: d, height: d))
            nodePath.lineWidth = 1.2
            nodePath.stroke()
        }

        switch status {
        case .merged:
            path.move(to: NSPoint(x: 4.6, y: 4.6))
            path.line(to: NSPoint(x: 7.1, y: 7.0))
            path.line(to: NSPoint(x: 9.2, y: 7.0))
            path.move(to: NSPoint(x: 4.6, y: 9.4))
            path.line(to: NSPoint(x: 7.1, y: 7.0))
            path.stroke()
            node(3.0, 3.0)
            node(3.0, 11.0)
            node(11.0, 7.0)
        default:
            path.move(to: NSPoint(x: 3.0, y: 4.8))
            path.line(to: NSPoint(x: 3.0, y: 9.2))
            path.move(to: NSPoint(x: 4.8, y: 3.0))
            path.line(to: NSPoint(x: 9.4, y: 3.0))
            path.line(to: NSPoint(x: 11.0, y: 4.6))
            path.line(to: NSPoint(x: 11.0, y: 9.2))
            path.stroke()
            node(3.0, 3.0)
            node(3.0, 11.0)
            node(11.0, 11.0)
        }
        context.restoreGState()
    }
}

/// Capsule progress bar (track + leading-anchored fill + optional label).
@MainActor
final class SidebarRowProgressView: NSView {
    private let trackView = NSView()
    private let fillView = NSView()
    let label = NSTextField(labelWithString: "")
    private var fraction: CGFloat = 0
    private var barHeight: CGFloat = 3

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        trackView.wantsLayer = true
        fillView.wantsLayer = true
        addSubview(trackView)
        addSubview(fillView)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        fraction: CGFloat,
        barHeight: CGFloat,
        trackColor: NSColor,
        fillColor: NSColor,
        labelText: String?,
        labelFont: NSFont,
        labelColor: NSColor
    ) {
        self.fraction = max(0, min(1, fraction))
        self.barHeight = barHeight
        trackView.layer?.backgroundColor = trackColor.cgColor
        fillView.layer?.backgroundColor = fillColor.cgColor
        label.isHidden = labelText == nil
        label.stringValue = labelText ?? ""
        label.font = labelFont
        label.textColor = labelColor
        needsLayout = true
    }

    static func height(barHeight: CGFloat, labelText: String?, labelFont: NSFont) -> CGFloat {
        guard labelText != nil else { return barHeight }
        return barHeight + 2 + ceil(labelFont.ascender - labelFont.descender + labelFont.leading)
    }

    override func layout() {
        super.layout()
        trackView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        trackView.layer?.cornerRadius = barHeight / 2
        fillView.frame = NSRect(x: 0, y: 0, width: bounds.width * fraction, height: barHeight)
        fillView.layer?.cornerRadius = barHeight / 2
        if !label.isHidden {
            let size = label.sidebarNaturalCellSize
            label.frame = NSRect(x: 0, y: barHeight + 2, width: min(ceil(size.width), bounds.width), height: size.height)
        }
    }
}

/// One wrapping/truncating text line (or block) with measured height.
@MainActor
final class SidebarRowTextView: NSTextField {
    var onOpenLink: ((URL) -> Void)?
    private var pendingLinkURL: URL?
    private var cachedLinkHitLayout: LinkHitLayout?

    private struct LinkHitLayout {
        let attributedString: NSAttributedString
        let textRectSize: NSSize
        let lineBreakMode: NSLineBreakMode
        let maximumNumberOfLines: Int
        let storage: NSTextStorage
        let layoutManager: NSLayoutManager
        let textContainer: NSTextContainer

        func matches(
            attributedString candidate: NSAttributedString,
            textRectSize candidateTextRectSize: NSSize,
            lineBreakMode candidateLineBreakMode: NSLineBreakMode,
            maximumNumberOfLines candidateMaximumNumberOfLines: Int
        ) -> Bool {
            textRectSize == candidateTextRectSize
                && lineBreakMode == candidateLineBreakMode
                && maximumNumberOfLines == candidateMaximumNumberOfLines
                && attributedString.isEqual(to: candidate)
        }
    }

    init(lines: Int) {
        super.init(frame: .zero)
        isEditable = false
        isBordered = false
        drawsBackground = false
        isSelectable = false
        lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        maximumNumberOfLines = lines
        cell?.truncatesLastVisibleLine = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = superview.map { convert(point, from: $0) } ?? point
        guard onOpenLink != nil, !isHidden, alphaValue > 0, linkURL(at: localPoint) != nil else {
            return nil
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard onOpenLink != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let url = linkURL(at: point) else {
            pendingLinkURL = nil
            return
        }
        pendingLinkURL = url
    }

    override func mouseUp(with event: NSEvent) {
        guard onOpenLink != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let pending = pendingLinkURL else { return }
        pendingLinkURL = nil
        guard linkURL(at: point) == pending else { return }
        onOpenLink?(pending)
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        guard !isHidden else { return 0 }
        let size = cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)) ?? .zero
        return ceil(size.height)
    }

    private func linkURL(at point: NSPoint) -> URL? {
        guard bounds.contains(point), attributedStringValue.length > 0 else {
            return nil
        }
        let textRect = cell?.titleRect(forBounds: bounds) ?? bounds
        guard textRect.contains(point), textRect.width > 0, textRect.height > 0 else {
            return nil
        }

        let layout = linkHitLayout(textRectSize: textRect.size)
        let layoutManager = layout.layoutManager
        let textContainer = layout.textContainer
        layoutManager.ensureLayout(for: textContainer)

        let usedRect = layoutManager.usedRect(for: textContainer)
        let textPoint = NSPoint(
            x: point.x - textRect.minX - usedRect.minX,
            y: point.y - textRect.minY - usedRect.minY
        )
        guard textPoint.x >= 0, textPoint.y >= 0,
              textPoint.x <= usedRect.width, textPoint.y <= usedRect.height
        else {
            return nil
        }

        let glyphIndex = layoutManager.glyphIndex(for: textPoint, in: textContainer)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        )
        guard glyphRect.contains(textPoint) else { return nil }

        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < attributedStringValue.length else { return nil }
        return Self.linkURL(from: attributedStringValue.attribute(.link, at: characterIndex, effectiveRange: nil))
    }

    private func linkHitLayout(textRectSize: NSSize) -> LinkHitLayout {
        if let cachedLinkHitLayout,
           cachedLinkHitLayout.matches(
               attributedString: attributedStringValue,
               textRectSize: textRectSize,
               lineBreakMode: lineBreakMode,
               maximumNumberOfLines: maximumNumberOfLines
           ) {
            return cachedLinkHitLayout
        }

        let storage = NSTextStorage(attributedString: attributedStringValue)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: textRectSize)
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = maximumNumberOfLines
        textContainer.lineBreakMode = lineBreakMode
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)

        let layout = LinkHitLayout(
            attributedString: attributedStringValue,
            textRectSize: textRectSize,
            lineBreakMode: lineBreakMode,
            maximumNumberOfLines: maximumNumberOfLines,
            storage: storage,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
        cachedLinkHitLayout = layout
        return layout
    }

    private static func linkURL(from value: Any?) -> URL? {
        switch value {
        case let url as URL:
            return url
        case let url as NSURL:
            return url as URL
        case let string as String:
            return URL(string: string)
        default:
            return nil
        }
    }
}
