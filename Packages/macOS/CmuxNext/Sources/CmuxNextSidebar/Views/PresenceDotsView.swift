import AppKit
import CmuxNextDesign
import QuartzCore

/// The agents acting in a workspace (cx-gg84): one round dot per agent in its
/// presence color (`AgentPresenceColor`), up to `maxDots`, then a `+n` count.
/// The tooltip lists each agent and what it touches.
final class PresenceDotsView: NSView {
    static let maxDots = 3
    private(set) var presence: [SidebarPresence] = []
    private var dots: [CALayer] = []
    private let overflow = SidebarRowView.label(font: SidebarStyle.subtitleFont)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay // updateLayer sets colors only
        overflow.isHidden = true
        addSubview(overflow)
        setAccessibilityElement(false)
        isHidden = true // no agents until configured
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }

    /// A row configures its dots on every content change: the same agents ask for no paint or layout.
    func configure(_ presence: [SidebarPresence]) {
        guard presence != self.presence else { return }
        self.presence = presence
        isHidden = presence.isEmpty
        let shown = min(presence.count, Self.maxDots)
        while dots.count < shown {
            let dot = CALayer()
            layer?.addSublayer(dot)
            dots.append(dot)
        }
        for (index, dot) in dots.enumerated() { dot.isHidden = index >= shown }
        overflow.setString(presence.count > shown ? Strings.presenceOverflow(presence.count - shown) : "")
        overflow.isHidden = overflow.stringValue.isEmpty
        themedToolTip = presence.isEmpty ? nil : presence.map(Strings.presenceLine).joined(separator: "\n")
        // invalidate: the agents changed (the guard above): other dot colors, count and width.
        needsLayout = true; needsDisplay = true
    }

    /// The width the dots and the count take.
    var preferredWidth: CGFloat {
        let shown = min(presence.count, Self.maxDots)
        guard shown > 0 else { return 0 }
        let d = SidebarStyle.dotSize
        let dotsWidth = CGFloat(shown) * d + CGFloat(shown - 1) * Metrics.space1
        // The count's frame holds its text and padding (`naturalSize`): the text alone clipped it.
        return overflow.isHidden ? dotsWidth : dotsWidth + Metrics.space1 + ceil(overflow.naturalSize.width)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let d = SidebarStyle.dotSize
        var x: CGFloat = 0
        for dot in dots where !dot.isHidden {
            // Width equals height and the radius is half of it: a true circle.
            dot.frame = CGRect(x: x, y: (bounds.height - d) / 2, width: d, height: d)
            dot.cornerRadius = d / 2
            x += d + Metrics.space1
        }
        if !overflow.isHidden {
            let size = overflow.naturalSize
            overflow.frame = NSRect(x: x, y: (bounds.height - ceil(size.height)) / 2, width: ceil(size.width), height: ceil(size.height))
        }
    }

    override func updateLayer() {
        performWithTheme {
            for (dot, agent) in zip(dots, presence) {
                dot.backgroundColor = AgentPresenceColor(key: agent.id).color.cgColor
            }
            overflow.setColor(Palette.textTertiary)
        }
    }
}
