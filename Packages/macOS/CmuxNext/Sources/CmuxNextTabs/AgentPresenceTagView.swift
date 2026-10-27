public import AppKit
import CmuxNextDesign

/// A pane's agent name tag (cx-gg84): who is acting in the pane's selected
/// tab and what it touches (`Claude Code · Editing app.rs:42`), in a
/// small-radius rect of the agent's presence color at the content's top-right.
/// It passes clicks through to the content under it.
public final class AgentPresenceTagView: NSView {
    let label = ChromeLabel(labelWithString: "")
    public private(set) var presence: TabPresence?

    override public init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = Metrics.space1
        layer?.cornerCurve = .continuous
        label.font = Typography.caption
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
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
        // An agent's next activity changes the text, which repaints itself; the fill and ink follow
        // the agent, and the pane frames the tag to its text (`layoutAgentTag`).
        let shownKey = self.presence?.colorKey
        self.presence = presence
        isHidden = presence == nil
        label.stringValue = presence?.summary ?? ""
        if label.font != Typography.caption {
            label.font = Typography.caption
            needsLayout = true // invalidate: a new text size (the check above) changes the label's height
        }
        if presence?.colorKey != shownKey { needsDisplay = true }
    }

    /// The tag's size for its text, at most `maxWidth` wide.
    public func fittingSize(maxWidth: CGFloat) -> NSSize {
        let text = labelSize
        let pad = Metrics.space2
        return NSSize(width: min(maxWidth, text.width + 2 * pad), height: text.height + Metrics.space1)
    }

    /// The label frame that draws the whole text. Not `intrinsicContentSize`:
    /// that is the alignment rect, 4 pt narrower than the cell draws in, and
    /// the cell cut 3-4 characters at that width. The cell needs its
    /// `cellSize` plus about a point (measured on macOS 26).
    private var labelSize: NSSize {
        let cell = label.naturalSize
        return NSSize(width: ceil(cell.width) + 1, height: ceil(label.intrinsicContentSize.height))
    }

    override public func layout() {
        super.layout()
        let h = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: Metrics.space2, y: (bounds.height - h) / 2, width: max(0, bounds.width - 2 * Metrics.space2), height: h)
    }

    override public func updateLayer() {
        guard let presence else { return }
        performWithTheme {
            layer?.backgroundColor = AgentPresenceColor(key: presence.colorKey).color.cgColor
            label.textColor = AgentPresenceColor(key: presence.colorKey).ink
        }
    }
}
