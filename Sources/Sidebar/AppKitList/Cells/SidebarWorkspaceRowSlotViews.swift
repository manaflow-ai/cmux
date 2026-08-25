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

extension NSAttributedString.Key {
    /// Row-owned replacement for `.link`. AppKit gives no way to override the
    /// color it paints `.link` runs in, so the sidebar carries the destination
    /// here and styles the run itself.
    static let sidebarRowLink = NSAttributedString.Key("com.cmux.sidebarRowLink")
}

/// One wrapping/truncating text line (or block) with measured height.
@MainActor
final class SidebarRowTextView: NSTextField {
    private typealias LinkDescriptor = (url: URL, characterRange: NSRange, label: String)

    /// Receives web-link clicks without making the field text-selectable.
    var onOpenLink: ((URL) -> Void)?
    private var pendingLinkURL: URL?
    private var cachedLinkHitLayout: LinkHitLayout?
    private var linkDescriptors: [LinkDescriptor] = []
    private var accessibilityLinks: [SidebarRowTextAccessibilityLink] = []
    // Before the first accessibility query, row updates retain only descriptors.
    // Once queried, stale proxies refresh across layout and content changes.
    private var accessibilityLinksWereRequested = false
    private var accessibilityLinksAreStale = false
    private var accessibilityLayoutSize: NSSize?

    override var isFlipped: Bool { true }
    override var isHidden: Bool {
        didSet {
            if isHidden,
               !oldValue,
               (!linkDescriptors.isEmpty || !accessibilityLinks.isEmpty) {
                invalidateLinkAccessibility()
            }
        }
    }

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

    override func layout() {
        super.layout()
        let textRectSize = (cell?.titleRect(forBounds: bounds) ?? bounds).size
        guard textRectSize != accessibilityLayoutSize else { return }
        accessibilityLayoutSize = textRectSize
        cachedLinkHitLayout = nil
        guard accessibilityLinksWereRequested else { return }
        accessibilityLinksAreStale = !linkDescriptors.isEmpty || !accessibilityLinks.isEmpty
        materializeAccessibilityLinks()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard accessibilityLinksWereRequested,
              window != nil,
              !isHidden,
              !linkDescriptors.isEmpty
        else { return }
        accessibilityLinksAreStale = true
        materializeAccessibilityLinks()
    }

    /// Vends the link proxies referenced by the accessibility attributed text.
    override func accessibilityChildren() -> [Any]? {
        guard !isHidden else { return [] }
        if !accessibilityLinksWereRequested {
            accessibilityLinksWereRequested = true
            accessibilityLinksAreStale = true
        }
        materializeAccessibilityLinks()
        var children = super.accessibilityChildren() ?? []
        for link in accessibilityLinks where !children.contains(where: {
            ($0 as? SidebarRowTextAccessibilityLink) === link
        }) {
            children.append(link)
        }
        return children
    }

    /// Applies the row palette to rendered Markdown while retaining ownership
    /// of link rendering and activation instead of delegating either to AppKit.
    func configureAttributedText(
        _ source: AttributedString,
        font: NSFont,
        color: NSColor,
        linkColor: NSColor
    ) {
        let mutable = NSMutableAttributedString(attributedString: NSAttributedString(source))
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.font, value: font, range: fullRange)
        mutable.addAttribute(.foregroundColor, value: color, range: fullRange)
        let nextLinkDescriptors = applyRowOwnedLinkStyling(to: mutable, linkColor: linkColor)
        attributedStringValue = mutable
        cachedLinkHitLayout = nil
        replaceLinkDescriptors(with: nextLinkDescriptors)
        needsLayout = true
    }

    /// Configures non-Markdown fallback text and removes stale link semantics
    /// left by a previous pooled-row configuration.
    func configurePlainText(_ text: String, font: NSFont, color: NSColor) {
        stringValue = text
        self.font = font
        textColor = color
        cachedLinkHitLayout = nil
        accessibilityLayoutSize = nil
        linkDescriptors = []
        replaceAccessibilityLinks(with: [])
        accessibilityLinksAreStale = false
        needsLayout = true
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
        openLink(pending)
    }

    /// Shared activation path for pointer and accessibility link actions.
    @discardableResult
    func openLink(_ url: URL) -> Bool {
        guard let onOpenLink else { return false }
        onOpenLink(url)
        return true
    }

    /// Activates an accessibility proxy only while its exact link range is visibly laid out.
    func openAccessibilityLink(_ url: URL, characterRange: NSRange) -> Bool {
        guard linkDescriptors.contains(where: {
            $0.url == url && $0.characterRange == characterRange
        }), !accessibilityFrame(forLinkRange: characterRange).isEmpty
        else { return false }
        return openLink(url)
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
        let textPoint = NSPoint(x: point.x - textRect.minX, y: point.y - textRect.minY)
        guard usedRect.contains(textPoint) else { return nil }

        let glyphIndex = layoutManager.glyphIndex(for: textPoint, in: textContainer)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        )
        guard glyphRect.contains(textPoint) else { return nil }
        guard !visibleGlyphRanges(
            in: NSRange(location: glyphIndex, length: 1),
            layoutManager: layoutManager,
            textContainer: textContainer
        ).isEmpty else { return nil }

        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < attributedStringValue.length else { return nil }
        return webURL(
            from: attributedStringValue.attribute(.sidebarRowLink, at: characterIndex, effectiveRange: nil)
        )
    }

    /// Moves every web `.link` run onto `.sidebarRowLink` so AppKit stops
    /// painting it, styles the run explicitly, and records lightweight semantics
    /// for accessibility proxies to materialize only at a real UI boundary.
    /// Non-web links are dropped, matching the metadata URL contract enforced
    /// elsewhere.
    private func applyRowOwnedLinkStyling(
        to mutable: NSMutableAttributedString,
        linkColor: NSColor
    ) -> [LinkDescriptor] {
        let fullRange = NSRange(location: 0, length: mutable.length)
        guard fullRange.length > 0 else { return [] }
        var runs: [(url: URL?, range: NSRange)] = []
        var nextLinkDescriptors: [LinkDescriptor] = []
        mutable.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard value != nil else { return }
            runs.append((webURL(from: value), range))
        }
        for run in runs {
            mutable.removeAttribute(.link, range: run.range)
            mutable.removeAttribute(.accessibilityLink, range: run.range)
            guard let url = run.url else {
                mutable.removeAttribute(.underlineStyle, range: run.range)
                continue
            }
            let label = mutable.attributedSubstring(from: run.range).string
            nextLinkDescriptors.append((url: url, characterRange: run.range, label: label))
            mutable.addAttributes(
                [
                    .sidebarRowLink: url,
                    .foregroundColor: linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: linkColor,
                ],
                range: run.range
            )
        }
        return nextLinkDescriptors
    }

    /// Resolves one proxy's frame on demand. Pointer hit testing and
    /// accessibility geometry share the cached TextKit layout, while normal
    /// row layout stays allocation-free for assistive-technology-only work.
    func accessibilityFrame(forLinkRange characterRange: NSRange) -> NSRect {
        guard !isHidden else { return .zero }
        let textRect = cell?.titleRect(forBounds: bounds) ?? bounds
        guard textRect.width > 0, textRect.height > 0 else { return .zero }
        let layout = linkHitLayout(textRectSize: textRect.size)
        let layoutManager = layout.layoutManager
        let textContainer = layout.textContainer
        layoutManager.ensureLayout(for: textContainer)
        let fullRange = NSRange(location: 0, length: attributedStringValue.length)
        let boundedCharacterRange = NSIntersectionRange(characterRange, fullRange)
        guard boundedCharacterRange.length > 0 else { return .zero }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: boundedCharacterRange,
            actualCharacterRange: nil
        )
        let visibleGlyphRanges = visibleGlyphRanges(
            in: glyphRange,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
        let containerBounds = NSRect(origin: .zero, size: textContainer.size)
        var resolvedFrame: NSRect?
        for visibleGlyphRange in visibleGlyphRanges {
            let part = layoutManager.boundingRect(
                forGlyphRange: visibleGlyphRange,
                in: textContainer
            ).intersection(containerBounds)
            guard !part.isEmpty else { continue }
            resolvedFrame = resolvedFrame.map { $0.union(part) } ?? part
        }
        guard var frame = resolvedFrame else { return .zero }
        frame.origin.x += textRect.minX
        frame.origin.y += textRect.minY
        return frame
    }

    private func visibleGlyphRanges(
        in glyphRange: NSRange,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> [NSRange] {
        let containerGlyphRange = layoutManager.glyphRange(for: textContainer)
        let candidateRange = NSIntersectionRange(glyphRange, containerGlyphRange)
        guard candidateRange.length > 0 else { return [] }

        var result: [NSRange] = []
        layoutManager.enumerateLineFragments(forGlyphRange: candidateRange) {
            _, _, _, lineGlyphRange, _ in
            let lineCandidate = NSIntersectionRange(candidateRange, lineGlyphRange)
            guard lineCandidate.length > 0 else { return }
            let truncatedRange = layoutManager.truncatedGlyphRange(
                inLineFragmentForGlyphAt: lineGlyphRange.location
            )
            guard truncatedRange.location != NSNotFound,
                  truncatedRange.length > 0
            else {
                result.append(lineCandidate)
                return
            }
            let hiddenRange = NSIntersectionRange(lineCandidate, truncatedRange)
            guard hiddenRange.length > 0 else {
                result.append(lineCandidate)
                return
            }
            if lineCandidate.location < hiddenRange.location {
                result.append(NSRange(
                    location: lineCandidate.location,
                    length: hiddenRange.location - lineCandidate.location
                ))
            }
            let hiddenEnd = NSMaxRange(hiddenRange)
            let lineEnd = NSMaxRange(lineCandidate)
            if hiddenEnd < lineEnd {
                result.append(NSRange(location: hiddenEnd, length: lineEnd - hiddenEnd))
            }
        }
        return result
    }

    /// Releases link state before the owning row takes on a new semantic identity.
    func invalidateLinkAccessibility() {
        let accessibilityWasRequested = accessibilityLinksWereRequested
        accessibilityLinksWereRequested = false
        accessibilityLinksAreStale = false
        guard pendingLinkURL != nil
            || !linkDescriptors.isEmpty
            || !accessibilityLinks.isEmpty
            || attributedStringValue.length > 0
            || cachedLinkHitLayout != nil
            || accessibilityWasRequested
        else { return }
        pendingLinkURL = nil
        linkDescriptors = []
        attributedStringValue = NSAttributedString(string: "")
        cachedLinkHitLayout = nil
        accessibilityLayoutSize = nil
        replaceAccessibilityLinks(with: [])
        needsLayout = true
    }

    private func replaceLinkDescriptors(with nextLinkDescriptors: [LinkDescriptor]) {
        linkDescriptors = nextLinkDescriptors
        guard accessibilityLinksWereRequested else { return }
        accessibilityLinksAreStale = !nextLinkDescriptors.isEmpty || !accessibilityLinks.isEmpty
        materializeAccessibilityLinks()
    }

    private func materializeAccessibilityLinks() {
        guard accessibilityLinksWereRequested, accessibilityLinksAreStale else { return }
        guard !linkDescriptors.isEmpty || !accessibilityLinks.isEmpty else {
            accessibilityLinksAreStale = false
            return
        }

        let textRectSize = (cell?.titleRect(forBounds: bounds) ?? bounds).size
        accessibilityLayoutSize = textRectSize
        let visibleLinkDescriptors = linkDescriptors.filter {
            !accessibilityFrame(forLinkRange: $0.characterRange).isEmpty
        }

        var reusableAccessibilityLinks:
            [URL: [NSRange: [String: SidebarRowTextAccessibilityLink]]] = [:]
        for link in accessibilityLinks {
            reusableAccessibilityLinks[link.url, default: [:]][link.characterRange, default: [:]][link.label] =
                link
        }

        let mutable = NSMutableAttributedString(attributedString: attributedStringValue)
        let fullRange = NSRange(location: 0, length: mutable.length)
        if fullRange.length > 0 {
            mutable.removeAttribute(.accessibilityLink, range: fullRange)
        }
        var nextAccessibilityLinks: [SidebarRowTextAccessibilityLink] = []
        for descriptor in visibleLinkDescriptors {
            let accessibilityLink: SidebarRowTextAccessibilityLink
            if let reusableLink = reusableAccessibilityLinks[descriptor.url]?[descriptor.characterRange]?[
                descriptor.label
            ] {
                accessibilityLink = reusableLink
            } else {
                accessibilityLink = SidebarRowTextAccessibilityLink(
                    owner: self,
                    characterRange: descriptor.characterRange,
                    label: descriptor.label,
                    url: descriptor.url
                )
            }
            nextAccessibilityLinks.append(accessibilityLink)
            mutable.addAttribute(
                .accessibilityLink,
                value: accessibilityLink,
                range: descriptor.characterRange
            )
        }

        attributedStringValue = mutable
        cachedLinkHitLayout = nil
        accessibilityLinksAreStale = false
        replaceAccessibilityLinks(with: nextAccessibilityLinks)
    }

    private func replaceAccessibilityLinks(
        with nextAccessibilityLinks: [SidebarRowTextAccessibilityLink]
    ) {
        let previousIdentities = accessibilityLinks.map(ObjectIdentifier.init)
        let nextIdentities = nextAccessibilityLinks.map(ObjectIdentifier.init)
        let retainedIdentities = Set(nextAccessibilityLinks.map { ObjectIdentifier($0) })
        for link in accessibilityLinks where !retainedIdentities.contains(ObjectIdentifier(link)) {
            link.invalidate()
        }
        accessibilityLinks = nextAccessibilityLinks
        guard previousIdentities != nextIdentities else { return }
        NSAccessibility.post(
            element: self,
            notification: .layoutChanged,
            userInfo: [.uiElements: nextAccessibilityLinks]
        )
    }

    private func linkHitLayout(textRectSize: NSSize) -> LinkHitLayout {
        let layoutLineBreakMode: NSLineBreakMode = if cell?.truncatesLastVisibleLine == true,
                                                     lineBreakMode == .byWordWrapping
                                                     || lineBreakMode == .byCharWrapping {
            .byTruncatingTail
        } else {
            lineBreakMode
        }
        if let cachedLinkHitLayout,
           cachedLinkHitLayout.textRectSize == textRectSize,
           cachedLinkHitLayout.lineBreakMode == layoutLineBreakMode,
           cachedLinkHitLayout.maximumNumberOfLines == maximumNumberOfLines,
           cachedLinkHitLayout.attributedString.isEqual(to: attributedStringValue) {
            return cachedLinkHitLayout
        }

        let storage = NSTextStorage(attributedString: attributedStringValue)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: textRectSize)
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = maximumNumberOfLines
        // NSTextContainer uses this mode only for its last line. Mirror
        // NSCell.truncatesLastVisibleLine so accessibility and pointer geometry
        // exclude the same glyphs that the field replaces with an ellipsis.
        textContainer.lineBreakMode = layoutLineBreakMode
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)

        let layout: LinkHitLayout = (
            attributedString: attributedStringValue,
            textRectSize: textRectSize,
            lineBreakMode: layoutLineBreakMode,
            maximumNumberOfLines: maximumNumberOfLines,
            storage: storage,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
        cachedLinkHitLayout = layout
        return layout
    }

    /// Matches the control-socket metadata URL contract in
    /// `upsertSidebarMetadata`: only HTTP(S) destinations are actionable.
    private func webURL(from value: Any?) -> URL? {
        let resolved: URL?
        switch value {
        case let candidate as URL:
            resolved = candidate
        case let candidate as NSURL:
            resolved = candidate as URL
        case let candidate as String:
            resolved = URL(string: candidate)
        default:
            resolved = nil
        }
        guard let resolved, let scheme = resolved.scheme?.lowercased() else { return nil }
        return scheme == "http" || scheme == "https" ? resolved : nil
    }
}
