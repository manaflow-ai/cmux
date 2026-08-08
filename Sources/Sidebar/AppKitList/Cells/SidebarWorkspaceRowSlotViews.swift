import AppKit
import CmuxFoundation
import CmuxSidebar
import CoreText

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

/// Adaptive unread-count badge shared by workspace and group rows.
/// Draws directly so the glyph is optically centered without NSTextField's
/// asymmetric cell insets.
@MainActor
final class SidebarRowUnreadBadgeView: NSView {
    private var textOutline: CGPath?
    private var textInkBounds: CGRect = .zero
    private var textHorizontalOpticalCenter: CGFloat = 0
    private var textAdvance: CGFloat = 0
    private var textLineHeight: CGFloat = 0
    private var fillColor: NSColor = .clear
    private var textColor: NSColor = .clear

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func accessibilityLabel(forUnreadCount count: Int) -> String {
        if count == 1 {
            return String(
                localized: "notification.unreadCount.one",
                defaultValue: "1 unread notification"
            )
        }
        return String.localizedStringWithFormat(
            String(
                localized: "notification.unreadCount.other",
                defaultValue: "%lld unread notifications"
            ),
            count
        )
    }

    func configure(count: Int, fillColor: NSColor, textColor: NSColor, font: NSFont) {
        let text = count > 99 ? "99+" : "\(max(0, count))"
        let attributedText = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: textColor]
        )
        let line = CTLineCreateWithAttributedString(attributedText)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        textAdvance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        textLineHeight = ascent + descent + leading
        textOutline = Self.makeTextOutline(line: line, font: font as CTFont)
        textInkBounds = textOutline?.boundingBoxOfPath ?? .zero
        textHorizontalOpticalCenter = textOutline
            .flatMap { Self.horizontalInkCentroid(of: $0, in: textInkBounds) }
            ?? textInkBounds.midX
        self.fillColor = fillColor
        self.textColor = textColor
        needsDisplay = true
    }

    private static func makeTextOutline(line: CTLine, font: CTFont) -> CGPath? {
        let outline = CGMutablePath()
        var appendedGlyph = false

        for case let run as CTRun in CTLineGetGlyphRuns(line) as NSArray {
            let glyphCount = CTRunGetGlyphCount(run)
            var glyphs = Array(repeating: CGGlyph(), count: glyphCount)
            var positions = Array(repeating: CGPoint.zero, count: glyphCount)
            glyphs.withUnsafeMutableBufferPointer { buffer in
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), buffer.baseAddress!)
            }
            positions.withUnsafeMutableBufferPointer { buffer in
                CTRunGetPositions(run, CFRange(location: 0, length: 0), buffer.baseAddress!)
            }

            for index in 0..<glyphCount {
                guard let glyphPath = CTFontCreatePathForGlyph(font, glyphs[index], nil) else {
                    continue
                }
                outline.addPath(
                    glyphPath,
                    transform: CGAffineTransform(
                        translationX: positions[index].x,
                        y: positions[index].y
                    )
                )
                appendedGlyph = true
            }
        }

        return appendedGlyph ? outline : nil
    }

    private static func horizontalInkCentroid(
        of outline: CGPath,
        in inkBounds: CGRect,
        renderingScale: CGFloat = 2
    ) -> CGFloat? {
        guard inkBounds.width.isFinite,
              inkBounds.height.isFinite,
              inkBounds.width > 0,
              inkBounds.height > 0,
              renderingScale > 0 else {
            return nil
        }

        let sampleRect = inkBounds.insetBy(dx: -1, dy: -1)
        let pixelsWide = max(1, Int(ceil(sampleRect.width * renderingScale)))
        let pixelsHigh = max(1, Int(ceil(sampleRect.height * renderingScale)))
        let bytesPerRow = pixelsWide
        var bitmap = [UInt8](repeating: 0, count: pixelsHigh * bytesPerRow)

        let totalWeight = bitmap.withUnsafeMutableBytes { buffer -> (weight: CGFloat, weightedX: CGFloat) in
            let pixels = buffer.bindMemory(to: UInt8.self)
            guard let context = CGContext(
                data: pixels.baseAddress,
                width: pixelsWide,
                height: pixelsHigh,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return (0, 0)
            }

            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.setFillColor(gray: 1, alpha: 1)
            context.scaleBy(x: renderingScale, y: renderingScale)
            context.translateBy(x: -sampleRect.minX, y: -sampleRect.minY)
            context.addPath(outline)
            context.fillPath()

            var weight: CGFloat = 0
            var weightedX: CGFloat = 0
            for y in 0..<pixelsHigh {
                let rowOffset = y * bytesPerRow
                for x in 0..<pixelsWide {
                    let pixelWeight = CGFloat(pixels[rowOffset + x])
                    guard pixelWeight > 0 else { continue }
                    let glyphX = sampleRect.minX + (CGFloat(x) + 0.5) / renderingScale
                    weight += pixelWeight
                    weightedX += glyphX * pixelWeight
                }
            }
            return (weight, weightedX)
        }

        guard totalWeight.weight > 0 else { return nil }
        return totalWeight.weightedX / totalWeight.weight
    }

    func fittingSize(horizontalPadding: CGFloat, minimumHeight: CGFloat) -> NSSize {
        let height = ceil(max(minimumHeight, textLineHeight + 2))
        return NSSize(
            width: ceil(max(height, textAdvance + horizontalPadding * 2)),
            height: height
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let textOutline, let context = NSGraphicsContext.current?.cgContext else { return }

        // Single digits occupy a square and therefore render as circles.
        // Wider counts expand horizontally into capsules without changing
        // their height or optical glyph centering.
        let badgeRect = bounds
        fillColor.setFill()
        NSBezierPath(
            roundedRect: badgeRect,
            xRadius: badgeRect.height / 2,
            yRadius: badgeRect.height / 2
        ).fill()

        // Measure and fill the same outline. Drawing the separately hinted
        // CTLine can snap a narrow digit to a different Retina pixel than the
        // outline used here. Horizontally, center the rendered ink mass rather
        // than its bounds so digits with asymmetric strokes do not read off
        // center inside a circular badge.
        context.saveGState()
        context.translateBy(
            x: badgeRect.midX - textHorizontalOpticalCenter,
            y: badgeRect.midY - textInkBounds.midY
        )
        textColor.setFill()
        context.addPath(textOutline)
        context.fillPath()
        context.restoreGState()
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
    /// Receives web-link clicks without making the field text-selectable.
    var onOpenLink: ((URL) -> Void)?
    private var pendingLinkURL: URL?
    private var cachedLinkHitLayout: LinkHitLayout?

    override var isFlipped: Bool { true }

    private typealias LinkHitLayout = (
        attributedString: NSAttributedString,
        textRectSize: NSSize,
        lineBreakMode: NSLineBreakMode,
        maximumNumberOfLines: Int,
        storage: NSTextStorage,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    )

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
        guard let superview else { return nil }
        let localPoint = convert(point, from: superview)
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
           cachedLinkHitLayout.textRectSize == textRectSize,
           cachedLinkHitLayout.lineBreakMode == lineBreakMode,
           cachedLinkHitLayout.maximumNumberOfLines == maximumNumberOfLines,
           cachedLinkHitLayout.attributedString.isEqual(to: attributedStringValue) {
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

        let layout: LinkHitLayout = (
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
        let resolvedURL: URL?
        switch value {
        case let candidate as URL:
            resolvedURL = candidate
        case let candidate as NSURL:
            resolvedURL = candidate as URL
        case let string as String:
            resolvedURL = URL(string: string)
        default:
            resolvedURL = nil
        }
        guard let resolvedURL, let scheme = resolvedURL.scheme?.lowercased() else {
            return nil
        }
        return scheme == "http" || scheme == "https" ? resolvedURL : nil
    }
}
