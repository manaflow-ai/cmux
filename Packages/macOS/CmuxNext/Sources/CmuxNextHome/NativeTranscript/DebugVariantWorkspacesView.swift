#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign

/// DEBUG ONLY, exploration (Home variations round 2): the first-run panel's picture of new
/// workspaces: the person's ask as a sent bubble, Chief's answer as a gray bubble, then one hairline
/// card per workspace (name, what runs in it, a status dot, its key). Draft copy, not localized.
final class DebugVariantWorkspacesView: NSView {
    struct Workspace: Sendable {
        var name: String
        var detail: String
        /// working | done | idle
        var status: String
        var key: String
    }

    var ask: String? { didSet { needsLayout = true } }
    var reply: String? { didSet { needsLayout = true } }
    var workspaces: [Workspace] = [] { didSet { rebuild() } }
    var compact = false { didSet { rebuild() } }
    var scale: CGFloat = 1 { didSet { rebuild() } }
    var colors: HomeFirstRunView.Colors? { didSet { applyColors() } }

    private let askBubble = NSView(), askLabel = ChromeLabel(wrappingLabelWithString: "")
    private let replyBubble = NSView(), replyLabel = ChromeLabel(wrappingLabelWithString: "")
    private var cards: [(card: NSView, title: ChromeLabel, detail: ChromeLabel, key: ChromeLabel, dot: NSView, status: String)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        for (bubble, label) in [(askBubble, askLabel), (replyBubble, replyLabel)] {
            bubble.wantsLayer = true
            bubble.layer?.cornerRadius = 17
            bubble.layer?.cornerCurve = .continuous
            label.maximumNumberOfLines = 0
            label.isSelectable = false
            bubble.addSubview(label)
            addSubview(bubble)
        }
    }

    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }

    private func rebuild() {
        for card in cards { card.card.removeFromSuperview() }
        cards = workspaces.map { workspace in
            let card = NSView()
            card.wantsLayer = true
            card.layer?.cornerRadius = 12
            card.layer?.cornerCurve = .continuous
            card.layer?.borderWidth = 1
            let title = ChromeLabel(labelWithString: workspace.name)
            let detail = ChromeLabel(labelWithString: workspace.detail)
            let key = ChromeLabel(labelWithString: workspace.key)
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 4 * scale
            for view in [title, detail, key, dot] { card.addSubview(view) }
            addSubview(card)
            return (card, title, detail, key, dot, workspace.status)
        }
        askLabel.font = .systemFont(ofSize: TypeScale.body * scale)
        replyLabel.font = .systemFont(ofSize: TypeScale.body * scale)
        for card in cards {
            card.title.font = .systemFont(ofSize: TypeScale.body * scale, weight: .semibold)
            card.detail.font = .systemFont(ofSize: TypeScale.detail * scale)
            card.key.font = .monospacedDigitSystemFont(ofSize: TypeScale.detail * scale, weight: .regular)
        }
        applyColors()
        needsLayout = true
    }

    private func applyColors() {
        guard let colors else { return }
        askBubble.layer?.backgroundColor = NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1).cgColor
        askLabel.textColor = .white
        replyBubble.layer?.backgroundColor = colors.hover.cgColor
        replyLabel.textColor = colors.primary
        for card in cards {
            card.card.layer?.backgroundColor = NSColor.clear.cgColor
            card.card.layer?.borderColor = colors.border.cgColor
            card.title.textColor = colors.primary
            card.detail.textColor = colors.secondary
            card.key.textColor = colors.tertiary
            let dot: NSColor = switch card.status {
            case "working": colors.attention
            case "done": colors.done
            default: colors.tertiary
            }
            card.dot.layer?.backgroundColor = dot.cgColor
        }
    }

    private var pad: CGFloat { 12 * scale }
    private var cardHeight: CGFloat { (compact ? 36 : 54) * scale }

    private func bubbleSize(_ label: ChromeLabel, width: CGFloat) -> CGSize {
        let inner = width * 0.78 - 2 * pad
        let size = label.size(forWidth: inner)
        return CGSize(width: ceil(size.width) + 2 * pad, height: ceil(size.height) + 16 * scale)
    }

    /// The view's height in a column `width` wide.
    func height(for width: CGFloat) -> CGFloat {
        var y: CGFloat = 0
        if ask != nil { askLabel.stringValue = ask ?? ""; y += bubbleSize(askLabel, width: width).height + 8 * scale }
        if reply != nil { replyLabel.stringValue = reply ?? ""; y += bubbleSize(replyLabel, width: width).height + 14 * scale }
        let gap = (compact ? 6 : 8) * scale
        if !cards.isEmpty { y += CGFloat(cards.count) * cardHeight + CGFloat(cards.count - 1) * gap }
        return ceil(y)
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        var y: CGFloat = 0
        askBubble.isHidden = ask == nil
        replyBubble.isHidden = reply == nil
        if let ask {
            askLabel.stringValue = ask
            let size = bubbleSize(askLabel, width: width)
            askBubble.frame = CGRect(x: width - size.width, y: y, width: size.width, height: size.height)
            askLabel.frame = CGRect(x: pad, y: 8 * scale, width: size.width - 2 * pad, height: size.height - 16 * scale)
            y += size.height + 8 * scale
        }
        if let reply {
            replyLabel.stringValue = reply
            let size = bubbleSize(replyLabel, width: width)
            replyBubble.frame = CGRect(x: 0, y: y, width: size.width, height: size.height)
            replyLabel.frame = CGRect(x: pad, y: 8 * scale, width: size.width - 2 * pad, height: size.height - 16 * scale)
            y += size.height + 14 * scale
        }
        let gap = (compact ? 6 : 8) * scale
        for card in cards {
            card.card.frame = CGRect(x: 0, y: y, width: width, height: cardHeight)
            let dot = 8 * scale
            let keyWidth = ceil(card.key.intrinsicContentSize.width)
            card.key.frame = CGRect(x: width - pad - keyWidth, y: (cardHeight - card.key.intrinsicContentSize.height) / 2,
                                    width: keyWidth, height: card.key.intrinsicContentSize.height)
            let textX = pad + dot + 10 * scale, textW = max(0, card.key.frame.minX - 8 * scale - textX)
            let titleH = card.title.intrinsicContentSize.height
            if compact {
                card.detail.isHidden = true
                card.title.frame = CGRect(x: textX, y: (cardHeight - titleH) / 2, width: textW, height: titleH)
            } else {
                card.detail.isHidden = false
                let detailH = card.detail.intrinsicContentSize.height, top = (cardHeight - titleH - detailH - 2 * scale) / 2
                card.title.frame = CGRect(x: textX, y: top, width: textW, height: titleH)
                card.detail.frame = CGRect(x: textX, y: top + titleH + 2 * scale, width: textW, height: detailH)
            }
            card.dot.frame = CGRect(x: pad, y: (cardHeight - dot) / 2, width: dot, height: dot)
            y += cardHeight + gap
        }
    }
}
#endif
