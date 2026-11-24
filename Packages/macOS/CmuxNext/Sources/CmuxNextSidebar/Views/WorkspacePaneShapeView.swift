import AppKit
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextWakeups

/// The hover card's miniature of a workspace's splits (``SidebarPaneShape``): one rounded tile per pane at its
/// real share of the screen showing the pane's front tab as it last looked (``SidebarTabThumbnails``, #51768), the
/// focused pane outlined in the accent. Until a tab has a picture (a chat never on screen since launch, a blank or
/// loading page, a shell showing only its prompt) its tile says what it is: its icon, title and folder or host.
/// Leo 2026-11-22 (ask-890db939a2): "i have this layout. so. the preview should be able to depict that."
///
/// While the card shows, its pictures refresh every ``refreshInterval``; a tile keeps its picture until a newer one
/// lands, so it never flashes back to the mark.
final class WorkspacePaneShapeView: NSView {
    /// The miniature's height; its width is the card's text column.
    static let height: CGFloat = 64
    static let gap: CGFloat = 3
    static let cornerRadius: CGFloat = 4
    static let markSize: CGFloat = 12
    /// The size pictures are asked at: a tile is at most the card's text column wide, at 2x.
    static let pictureSize = CGSize(width: 640, height: 320)
    /// How long after its last pictures a showing card asks for newer ones (a running terminal, a chat that moved on).
    static let refreshInterval: Duration = .seconds(1)

    var shape: SidebarPaneShape? {
        didSet {
            guard shape != oldValue else { return }
            isHidden = shape == nil
            needsDisplay = true
            setAccessibilityLabel(shape.map { Self.accessibilityText($0) })
        }
    }

    /// What a tile with no picture says, by its pane's front tab (``label(for:)``).
    var labels: [TabID: Label] = [:] {
        didSet { if labels != oldValue { needsDisplay = true } }
    }

    /// A pictureless tile's text: its tab's icon, title and a second line (a folder, a page's host).
    struct Label: Equatable {
        var icon: IconName
        var title: String
        var detail: String?
    }

    /// Where the tiles' pictures come from: the hover card controller's store (a test's own).
    var thumbnails = SidebarTabThumbnails()
    /// The next refresh while the card shows; one-shot, scheduled again by each refresh.
    private let refreshTimer = DemandTimer(owner: "sidebar.hover-card.pane-pictures")

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    init() {
        super.init(frame: .zero)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier("cmux.sidebar.hoverCard.paneShape")
    }

    nonisolated deinit { refreshTimer.cancel() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Pictures

    /// Asks for each tile's newest picture now and keeps asking while the card shows (the card calls this on each
    /// show). The last pictures draw meanwhile.
    func refreshThumbnails() {
        guard let shape, thumbnails.provider != nil else { return stopRefreshing() }
        for tab in shape.tabs {
            Task { [weak self, thumbnails] in  // task-owner: one bounded picture request; a closed card ignores it
                if await thumbnails.refresh(tab, maxPixelSize: Self.pictureSize) { self?.needsDisplay = true }
            }
        }
        // hover-timing: picture refresh cadence while the card shows, not a delay
        refreshTimer.scheduleIfIdle(after: Self.refreshInterval) { @MainActor [weak self] in self?.refreshTick() }
    }

    /// The tab whose picture tile `index` shows, when it has one (tests).
    func thumbnail(ofTile index: Int) -> CGImage? {
        guard let panes = shape?.frames(in: .zero, gap: 0), panes.indices.contains(index), let tab = panes[index].pane.tab else { return nil }
        return thumbnails.image(for: tab)
    }

    /// What `tab`'s tile says while it has no picture: a chat's or terminal's title over its folder, a page's title
    /// over its host, and a blank or loading page (no title, no host yet) as a New Tab, never an empty box.
    static func label(for tab: SidebarTab) -> Label {
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch tab.kind {
        case .newTab:
            return Label(icon: tab.kind.icon, title: Strings.hoverCardNewTab)
        case .browser:
            let shown = title.isEmpty || title == "about:blank" ? tab.host ?? Strings.hoverCardNewTab : title
            return Label(icon: tab.kind.icon, title: shown, detail: tab.host == shown ? nil : tab.host)
        default:
            let detail = tab.folder ?? tab.branch
            return Label(icon: tab.kind.icon, title: title.isEmpty ? detail ?? "" : title, detail: title.isEmpty ? nil : detail)
        }
    }

    /// What tile `index` says while it has no picture (tests).
    func label(ofTile index: Int) -> Label? {
        guard let panes = shape?.frames(in: .zero, gap: 0), panes.indices.contains(index), let tab = panes[index].pane.tab else { return nil }
        return labels[tab]
    }

    private func refreshTick() {
        // A card put away (ordered out, hidden or closed) stops asking; its next show starts again.
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { return stopRefreshing() }
        refreshThumbnails()
    }

    private func stopRefreshing() { refreshTimer.cancel() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopRefreshing() }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let shape else { return }
        performWithTheme {
            let fill = Palette.textPrimary.withAlphaComponent(0.07)
            let edge = Palette.textPrimary.withAlphaComponent(0.16)
            let focus = Palette.accent
            let markTint = Palette.textSecondary.cgColor
            for (frame, pane) in shape.frames(in: bounds.insetBy(dx: 0.5, dy: 0.5), gap: Self.gap) {
                let path = NSBezierPath(roundedRect: frame, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
                fill.setFill()
                path.fill()
                let picture = pane.tab.flatMap { thumbnails.image(for: $0) }
                if let picture { Self.draw(picture, filling: frame, clippedTo: path) }
                (pane.focused ? focus : edge).setStroke()
                path.lineWidth = pane.focused ? 1.5 : 1
                path.stroke()
                guard picture == nil else { continue }
                if let label = pane.tab.flatMap({ labels[$0] }), !label.title.isEmpty, frame.width >= Self.labelMinWidth,
                   frame.height >= Self.labelMinHeight {
                    drawLabel(label, in: frame, clippedTo: path, tint: markTint)
                } else if let kind = pane.kind {
                    drawMark(kind.iconName, centeredIn: frame, tint: markTint)
                }
            }
        }
    }

    /// The smallest tile that says its tab's title; a smaller one shows its kind's mark only.
    static let labelMinWidth: CGFloat = 44
    static let labelMinHeight: CGFloat = 20
    static let labelInset: CGFloat = 5

    /// A mark only where it fits with room around it, so a sliver of a pane reads as a pane, not a glyph.
    private func drawMark(_ icon: IconName, centeredIn frame: CGRect, tint: CGColor) {
        guard frame.width >= Self.markSize * 2, frame.height >= Self.markSize * 2 else { return }
        drawIcon(icon, in: CGRect(x: frame.midX - Self.markSize / 2, y: frame.midY - Self.markSize / 2, width: Self.markSize, height: Self.markSize), tint: tint)
    }

    private func drawIcon(_ icon: IconName, in mark: CGRect, tint: CGColor) {
        guard let image = CGImage.icon(icon, size: Self.markSize, scale: window?.backingScaleFactor ?? 2, tint: tint),
              let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // The view is flipped; a CGImage draws bottom-up.
        context.translateBy(x: 0, y: mark.maxY + mark.minY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: mark)
        context.restoreGState()
    }

    /// The tab's icon and title on the tile's first line, its detail under them where the tile has room.
    private func drawLabel(_ label: Label, in frame: CGRect, clippedTo path: NSBezierPath, tint: CGColor) {
        let inset = Self.labelInset
        let font = Typography.caption
        let line = ceil(font.ascender - font.descender + font.leading)
        let firstY = frame.minY + inset - 1
        drawIcon(label.icon, in: CGRect(x: frame.minX + inset, y: firstY + (line - Self.markSize) / 2, width: Self.markSize, height: Self.markSize), tint: tint)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let textX = frame.minX + inset + Self.markSize + 4
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        (label.title as NSString).draw(with: CGRect(x: textX, y: firstY, width: max(0, frame.maxX - inset - textX), height: line),
                                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                       attributes: [.font: font, .foregroundColor: Palette.textPrimary, .paragraphStyle: style])
        if let detail = label.detail, frame.height >= inset * 2 + line * 2 {
            (detail as NSString).draw(with: CGRect(x: frame.minX + inset, y: firstY + line, width: max(0, frame.width - inset * 2), height: line),
                                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                      attributes: [.font: font, .foregroundColor: Palette.textSecondary, .paragraphStyle: style])
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Draws `image` over `frame`, scaled to fill it and kept to its top (a page's head, a chat's header), clipped to
    /// the tile's rounded `path`. The view is flipped; a CGImage draws bottom-up.
    private static func draw(_ image: CGImage, filling frame: CGRect, clippedTo path: NSBezierPath) {
        guard let context = NSGraphicsContext.current?.cgContext, image.width > 0, image.height > 0 else { return }
        let rect = fillRect(for: CGSize(width: image.width, height: image.height), in: frame)
        context.saveGState()
        path.addClip()
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: rect.maxY + rect.minY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: rect)
        context.restoreGState()
    }

    /// Where a picture of `size` draws to fill `frame` (flipped space): scaled to cover it, centered across, top on
    /// the frame's top.
    static func fillRect(for size: CGSize, in frame: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return frame }
        let scale = max(frame.width / size.width, frame.height / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: frame.midX - drawn.width / 2, y: frame.minY, width: drawn.width, height: drawn.height)
    }

    func applyColors() { needsDisplay = true }

    /// "Panes: 3" for VoiceOver.
    static func accessibilityText(_ shape: SidebarPaneShape) -> String { Strings.paneCount(shape.paneCount) }
}
