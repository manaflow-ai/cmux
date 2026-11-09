public import AppKit
import CmuxNextDesign

/// A pane's agent name tag (cx-gg84): who is acting in the pane's selected
/// tab and what it touches (`Claude Code · Editing app.rs:42`), in a
/// small-radius rect of the agent's presence color at the content's top-right.
/// An agent driving the screen or a browser (`TabPresence.drive`) leads with that
/// glyph, the same mark as its tab chip and sidebar row. It passes clicks through
/// to the content under it.
public final class AgentPresenceTagView: NSView {
    let label = ChromeLabel(labelWithString: "")
    /// What the agent drives, before the text; hidden for quieter activity.
    private let glyph = CALayer()
    private static let glyphSide: CGFloat = 11
    public private(set) var presence: TabPresence?

    override public init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Metrics.controlCornerRadius
        layer?.cornerCurve = .continuous
        label.font = Typography.caption
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
        glyph.contentsGravity = .resizeAspect
        glyph.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(glyph)
        isHidden = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override public var wantsUpdateLayer: Bool { true }
    override public var isFlipped: Bool { true }
    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    public func configure(_ presence: TabPresence?) {
        guard presence != self.presence else { return }
        self.presence = presence
        isHidden = presence == nil
        label.stringValue = presence?.summary ?? ""
        label.font = Typography.caption
        needsDisplay = true
        needsLayout = true
    }

    /// Places the tag at `content`'s top-right with its top at `top` (both in the superview's
    /// coordinates), left of the `trailing` width another corner control takes (the zoom indicator).
    public func place(in content: NSRect, top: CGFloat, trailing: CGFloat = 0) {
        let inset = Metrics.space2
        let size = fittingSize(maxWidth: max(0, content.width / 2 - inset - trailing))
        frame = NSRect(x: content.maxX - inset - trailing - size.width, y: top + inset, width: size.width, height: size.height)
    }

    /// The tag's size for its text, at most `maxWidth` wide.
    public func fittingSize(maxWidth: CGFloat) -> NSSize {
        let text = labelSize
        let pad = Metrics.space2
        return NSSize(width: min(maxWidth, text.width + 2 * pad + glyphWidth), height: text.height + Metrics.space1)
    }

    /// The label frame that draws the whole text. Not `intrinsicContentSize`:
    /// that is the alignment rect, 4 pt narrower than the cell draws in, and
    /// the cell cut 3-4 characters at that width. The cell needs its
    /// `cellSize` plus about a point (measured on macOS 26).
    private var labelSize: NSSize {
        let cell = label.naturalSize
        return NSSize(width: ceil(cell.width) + 1, height: ceil(label.intrinsicContentSize.height))
    }

    /// The glyph and its gap, 0 without a drive.
    private var glyphWidth: CGFloat { presence?.drive == nil ? 0 : Self.glyphSide + Metrics.space1 }

    override public func layout() {
        super.layout()
        let h = ceil(label.intrinsicContentSize.height), g = Self.glyphSide
        glyph.frame = presence?.drive == nil ? .zero : CGRect(x: Metrics.space2, y: (bounds.height - g) / 2, width: g, height: g)
        let x = Metrics.space2 + glyphWidth
        label.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: max(0, bounds.width - x - Metrics.space2), height: h)
    }

    override public func updateLayer() {
        guard let presence else { return }
        performWithTheme {
            let agent = AgentPresenceColor(key: presence.colorKey)
            layer?.backgroundColor = agent.color.cgColor
            label.textColor = agent.ink
            let scale = window?.backingScaleFactor ?? 2
            glyph.contentsScale = scale
            glyph.contents = presence.drive.flatMap { drive in
                let config = NSImage.SymbolConfiguration(pointSize: Self.glyphSide, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [agent.ink]))
                return NSImage(systemSymbolName: drive.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(config)?.layerContents(forContentsScale: scale)
            }
        }
    }
}
