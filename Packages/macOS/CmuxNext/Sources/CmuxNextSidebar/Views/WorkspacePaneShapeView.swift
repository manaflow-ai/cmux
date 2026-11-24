import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The hover card's miniature of a workspace's splits (``SidebarPaneShape``): one rounded tile per pane at its
/// real share of the screen, the pane's front tab's mark in it, the focused pane outlined in the accent.
/// Leo 2026-11-22 (ask-890db939a2): "i have this layout. so. the preview should be able to depict that."
final class WorkspacePaneShapeView: NSView {
    /// The miniature's height; its width is the card's text column.
    static let height: CGFloat = 88
    static let gap: CGFloat = 3
    static let cornerRadius: CGFloat = 4
    static let markSize: CGFloat = 12

    /// What a tile says about its tab, by the tab's id: the title, and the state word when it has one.
    struct Caption: Hashable {
        var title: String
        var state: String?
    }

    /// The tabs' captions (a tile with no picture shows its title and state, never a bare glyph).
    var captions: [String: Caption] = [:] {
        didSet { if captions != oldValue { needsDisplay = true } }
    }

    /// The tabs' pictures as they land; a tile draws its picture filling it.
    private(set) var images: [String: CGImage] = [:]

    func setImage(_ image: CGImage?, for tab: String) {
        guard images[tab] != nil || image != nil else { return }
        images[tab] = image
        needsDisplay = true
    }

    /// Drops pictures of tabs the miniature no longer shows (the card is reused across workspaces).
    func pruneImages(keeping tabs: [String]) {
        let kept = images.filter { tabs.contains($0.key) }
        guard kept.count != images.count else { return }
        images = kept
        needsDisplay = true
    }

    /// The tab ids the miniature's panes show.
    var tabIDs: [String] { shape?.frames(in: .init(x: 0, y: 0, width: 1, height: 1), gap: 0).compactMap(\.pane.tab) ?? [] }

    var shape: SidebarPaneShape? {
        didSet {
            guard shape != oldValue else { return }
            isHidden = shape == nil
            needsDisplay = true
            setAccessibilityLabel(shape.map { Self.accessibilityText($0) })
        }
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    init() {
        super.init(frame: .zero)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier("cmux.sidebar.hoverCard.paneShape")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
                (pane.focused ? focus : edge).setStroke()
                path.lineWidth = pane.focused ? 1.5 : 1
                path.stroke()
                if let tab = pane.tab, drawPicture(images[tab], in: frame, path: path) {
                    (pane.focused ? focus : edge).setStroke()
                    path.lineWidth = pane.focused ? 1.5 : 1
                    path.stroke()
                    continue
                }
                if let tab = pane.tab, let caption = captions[tab], drawCaption(caption, kind: pane.kind, in: frame, tint: markTint) { continue }
                // A mark only where it fits with room around it, so a sliver of a pane reads as a pane, not a glyph.
                guard let kind = pane.kind, frame.width >= Self.markSize * 2, frame.height >= Self.markSize * 2,
                      let image = CGImage.icon(kind.iconName, size: Self.markSize, scale: window?.backingScaleFactor ?? 2, tint: markTint),
                      let context = NSGraphicsContext.current?.cgContext else { continue }
                let mark = CGRect(x: frame.midX - Self.markSize / 2, y: frame.midY - Self.markSize / 2,
                                  width: Self.markSize, height: Self.markSize)
                context.saveGState()
                // The view is flipped; a CGImage draws bottom-up.
                context.translateBy(x: 0, y: mark.maxY + mark.minY)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: mark)
                context.restoreGState()
            }
        }
    }

    /// `image` filling `frame` (cropped, never stretched), clipped to the tile's rounded shape.
    private func drawPicture(_ image: CGImage?, in frame: CGRect, path: NSBezierPath) -> Bool {
        guard let image, let context = NSGraphicsContext.current?.cgContext, frame.width > 0, frame.height > 0 else { return false }
        let size = CGSize(width: image.width, height: image.height)
        let scale = max(frame.width / size.width, frame.height / size.height)
        let drawn = CGRect(x: frame.midX - size.width * scale / 2, y: frame.midY - size.height * scale / 2,
                           width: size.width * scale, height: size.height * scale)
        context.saveGState()
        path.addClip()
        context.translateBy(x: 0, y: drawn.maxY + drawn.minY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: drawn)
        context.restoreGState()
        return true
    }

    /// The tile's title (up to two lines) and state word, left-aligned in the tile, over its kind's mark when it is
    /// tall enough; false when the tile is too small to read anything.
    private func drawCaption(_ caption: Caption, kind: SidebarWorkspaceKind?, in frame: CGRect, tint: CGColor) -> Bool {
        let inset: CGFloat = 6
        guard frame.width >= 40, frame.height >= 30 else { return false }
        let titleFont = Typography.bodyEmphasized
        let stateFont = Typography.caption
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let area = frame.insetBy(dx: inset, dy: inset)
        var y = area.minY
        if let kind, frame.height >= 52, let image = CGImage.icon(kind.iconName, size: Self.markSize, scale: window?.backingScaleFactor ?? 2, tint: tint),
           let context = NSGraphicsContext.current?.cgContext {
            let mark = CGRect(x: area.minX, y: y, width: Self.markSize, height: Self.markSize)
            context.saveGState()
            context.translateBy(x: 0, y: mark.maxY + mark.minY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: mark)
            context.restoreGState()
            y += Self.markSize + 4
        }
        let lineHeight = ceil(titleFont.boundingRectForFont.height)
        let stateHeight = caption.state == nil ? 0 : ceil(stateFont.boundingRectForFont.height)
        let titleLines = max(1, min(2, Int((area.maxY - y - stateHeight) / lineHeight)))
        let titleRect = CGRect(x: area.minX, y: y, width: area.width, height: lineHeight * CGFloat(titleLines))
        paragraph.lineBreakMode = titleLines > 1 ? .byWordWrapping : .byTruncatingTail
        (caption.title as NSString).draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                         attributes: [.font: titleFont, .foregroundColor: Palette.textPrimary, .paragraphStyle: paragraph])
        if let state = caption.state, titleRect.maxY + stateHeight <= area.maxY + 2 {
            paragraph.lineBreakMode = .byTruncatingTail
            (state as NSString).draw(with: CGRect(x: area.minX, y: titleRect.maxY, width: area.width, height: stateHeight),
                                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                     attributes: [.font: stateFont, .foregroundColor: Palette.textSecondary, .paragraphStyle: paragraph])
        }
        return true
    }

    func applyColors() { needsDisplay = true }

    /// "Panes: 3" for VoiceOver.
    static func accessibilityText(_ shape: SidebarPaneShape) -> String { Strings.paneCount(shape.paneCount) }
}
