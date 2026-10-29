import AppKit

/// One wrapping/truncating text line (or block) with measured height.
@MainActor
final class SidebarRowTextView: NSTextField {
    private typealias LinkDescriptor = (url: URL, characterRange: NSRange, label: String)

    /// Receives web-link clicks without making the field text-selectable.
    var onOpenLink: ((URL) -> Void)?
    private var pendingLinkURL: URL?
    private var cachedLinkHitLayout: SidebarRowTextLinkLayout?
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

    init(lines: Int) {
        super.init(frame: .zero)
        isEditable = false
        isBordered = false
        drawsBackground = false
        isSelectable = false
        // Own the text element as well as its link children. NSTextField is
        // otherwise ignored and delegates its readable value to NSCell.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
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
        materializeAccessibilityLinks(notifyChanges: false)
        // This read-only field exposes its text value directly. Forwarding
        // NSTextField's cell children can alias the field itself and create an
        // accessibility cycle through NSTableView's cell mock element. Only
        // the row-owned link proxies are children of this view.
        return accessibilityLinks
    }

    /// Translate the cell's text attributes for AX without setting its value.
    /// A setter here posts observed-value notifications and can re-enter this
    /// getter through NSTableView's synthesized cell element.
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        let length = attributedStringValue.length
        guard !isHidden, range.location >= 0, range.location <= length,
              range.length >= 0, range.length <= length - range.location,
              let text = cell?.accessibilityAttributedString(for: range)
        else { return nil }
        _ = accessibilityChildren()
        let result = NSMutableAttributedString(attributedString: text)
        for link in accessibilityLinks {
            let intersection = NSIntersectionRange(range, link.characterRange)
            guard intersection.length > 0 else { continue }
            result.addAttribute(.accessibilityLink, value: link, range: NSRange(
                location: intersection.location - range.location,
                length: intersection.length
            ))
        }
        return result
    }

    override func accessibilityNumberOfCharacters() -> Int {
        attributedStringValue.length
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        cell?.accessibilityVisibleCharacterRange() ?? NSRange(location: 0, length: 0)
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
        // Publish descriptors before the setter can notify an AX observer.
        cachedLinkHitLayout = nil
        linkDescriptors = nextLinkDescriptors
        accessibilityLinksAreStale = accessibilityLinksWereRequested
        attributedStringValue = mutable
        materializeAccessibilityLinks()
        needsLayout = true
    }

    /// Configures non-Markdown fallback text and removes stale link semantics
    /// left by a previous pooled-row configuration.
    func configurePlainText(_ text: String, font: NSFont, color: NSColor) {
        cachedLinkHitLayout = nil
        accessibilityLayoutSize = nil
        linkDescriptors = []
        accessibilityLinksAreStale = accessibilityLinksWereRequested
        stringValue = text
        self.font = font
        textColor = color
        accessibilityLinksAreStale = false
        replaceAccessibilityLinks(with: [])
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
        guard bounds.contains(point), attributedStringValue.length > 0 else { return nil }
        let textRect = cell?.titleRect(forBounds: bounds) ?? bounds
        guard textRect.contains(point), textRect.width > 0, textRect.height > 0 else { return nil }
        let layout = linkHitLayout(textRectSize: textRect.size)
        let textPoint = NSPoint(x: point.x - textRect.minX, y: point.y - textRect.minY)
        guard let characterIndex = layout.characterIndex(at: textPoint) else { return nil }
        return webURL(from: attributedStringValue.attribute(
            .sidebarRowLink, at: characterIndex, effectiveRange: nil
        ))
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
        let frame = layout.frame(forCharacterRange: characterRange)
        guard !frame.isEmpty else { return .zero }
        return frame.offsetBy(dx: textRect.minX, dy: textRect.minY)
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
        cachedLinkHitLayout = nil
        accessibilityLayoutSize = nil
        attributedStringValue = NSAttributedString(string: "")
        replaceAccessibilityLinks(with: [])
        needsLayout = true
    }

    private func materializeAccessibilityLinks(notifyChanges: Bool = true) {
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
        }

        accessibilityLinksAreStale = false
        replaceAccessibilityLinks(with: nextAccessibilityLinks, notifyChanges: notifyChanges)
    }

    private func replaceAccessibilityLinks(
        with nextAccessibilityLinks: [SidebarRowTextAccessibilityLink],
        notifyChanges: Bool = true
    ) {
        let previousIdentities = accessibilityLinks.map(ObjectIdentifier.init)
        let nextIdentities = nextAccessibilityLinks.map(ObjectIdentifier.init)
        let retainedIdentities = Set(nextAccessibilityLinks.map { ObjectIdentifier($0) })
        let previousLinks = accessibilityLinks
        accessibilityLinks = nextAccessibilityLinks
        for link in previousLinks where !retainedIdentities.contains(ObjectIdentifier(link)) {
            link.invalidate(notify: notifyChanges)
        }
        guard notifyChanges, previousIdentities != nextIdentities else { return }
        NSAccessibility.post(
            element: self,
            notification: .layoutChanged,
            userInfo: [.uiElements: nextAccessibilityLinks]
        )
    }

    private func linkHitLayout(textRectSize: NSSize) -> SidebarRowTextLinkLayout {
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

        let layout = SidebarRowTextLinkLayout(
            attributedString: attributedStringValue,
            textRectSize: textRectSize,
            lineBreakMode: layoutLineBreakMode,
            maximumNumberOfLines: maximumNumberOfLines
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
