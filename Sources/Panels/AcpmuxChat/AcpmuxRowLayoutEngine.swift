import AppKit
import CmuxAcpmux

/// Computes and caches ``AcpmuxRowLayout``s keyed by row id, content version, width,
/// group position, and expansion, so scrolling and unrelated updates never re-measure.
@MainActor
final class AcpmuxRowLayoutEngine {
    private struct Key: Hashable {
        let id: String
        let version: Int
        let width: Int
        let position: AcpmuxRowGroupPosition
        let expanded: Bool
    }

    private(set) var renderer: AcpmuxChatTextRenderer
    private let measurer = AcpmuxTextMeasurer()
    private var cache: [Key: AcpmuxRowLayout] = [:]
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static let sideInset: CGFloat = 16
    static let bubbleHorizontalPadding: CGFloat = 12
    static let bubbleVerticalPadding: CGFloat = 8
    static let typingSize = CGSize(width: 58, height: 34)

    init(theme: AcpmuxChatTheme) {
        renderer = AcpmuxChatTextRenderer(theme: theme)
    }

    var theme: AcpmuxChatTheme { renderer.theme }

    func setTheme(_ theme: AcpmuxChatTheme) {
        guard theme != renderer.theme else { return }
        renderer = AcpmuxChatTextRenderer(theme: theme)
        cache.removeAll()
    }

    /// Drops cached layouts for widths other than `width`, bounding memory during resizes.
    func retainOnly(width: CGFloat) {
        let keep = Int(width.rounded())
        cache = cache.filter { $0.key.width == keep }
    }

    func layout(for row: TranscriptRow, position: AcpmuxRowGroupPosition, width: CGFloat, expanded: Bool) -> AcpmuxRowLayout {
        let key = Key(id: row.id, version: row.version, width: Int(width.rounded()), position: position, expanded: expanded)
        if let cached = cache[key] { return cached }
        let computed = compute(row, position: position, width: max(width, 120), expanded: expanded)
        cache[key] = computed
        return computed
    }

    private func compute(_ row: TranscriptRow, position: AcpmuxRowGroupPosition, width: CGFloat, expanded: Bool) -> AcpmuxRowLayout {
        let side = Self.sideInset
        let timestamp = row.at > 0 ? timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(row.at) / 1000)) : nil
        switch row.content {
        case .user(let message):
            var text = renderer.userMessage(message.text)
            if message.failed {
                let marked = NSMutableAttributedString(attributedString: text)
                marked.append(NSAttributedString(
                    string: "\n" + String(localized: "acpmuxChat.message.notDelivered", defaultValue: "Not delivered"),
                    attributes: [.font: renderer.theme.smallFont, .foregroundColor: renderer.theme.userText.withAlphaComponent(0.8)]
                ))
                text = marked
            }
            let maxBubble = min(width * 0.75, 560)
            return bubble(text, trailing: true, maxBubble: maxBubble, width: width, position: position,
                          surface: .userBubble, dimmed: message.isPending, timestamp: timestamp)
        case .assistant(let markdown, _):
            let maxBubble = min(width - 2 * side - 36, 760)
            return bubble(renderer.markdown(markdown), trailing: false, maxBubble: maxBubble, width: width,
                          position: position, surface: .assistantBubble, dimmed: false, timestamp: timestamp)
        case .activity(let group):
            return plain(renderer.activity(group, expanded: expanded), width: width, top: 4, bottom: 4,
                         indent: side + 4, toggleable: true, timestamp: timestamp)
        case .plan(let entries):
            return card(renderer.plan(entries), width: width, timestamp: timestamp)
        case .permission(let card):
            return plain(renderer.permission(card), width: width, top: 4, bottom: 4, indent: side + 4,
                         toggleable: false, timestamp: timestamp)
        case .turnSummary(let summary):
            return plain(renderer.turnSummary(summary), width: width, top: 10, bottom: 14, indent: side,
                         toggleable: false, timestamp: timestamp)
        case .notice(let text):
            return plain(renderer.notice(text), width: width, top: 8, bottom: 8, indent: side,
                         toggleable: false, timestamp: timestamp)
        case .typing:
            let top: CGFloat = 8
            let frame = CGRect(origin: CGPoint(x: side, y: top), size: Self.typingSize)
            return AcpmuxRowLayout(height: top + frame.height + 6, surfaceFrame: frame, textFrame: .zero,
                                   text: NSAttributedString(), surface: .typing, showsTail: true,
                                   isToggleable: false, dimmed: false, timestamp: nil)
        }
    }

    private func bubble(
        _ text: NSAttributedString,
        trailing: Bool,
        maxBubble: CGFloat,
        width: CGFloat,
        position: AcpmuxRowGroupPosition,
        surface: AcpmuxRowLayout.Surface,
        dimmed: Bool,
        timestamp: String?
    ) -> AcpmuxRowLayout {
        let horizontal = Self.bubbleHorizontalPadding
        let vertical = Self.bubbleVerticalPadding
        let textSize = measurer.size(of: text, width: max(40, maxBubble - 2 * horizontal))
        let bubbleWidth = min(maxBubble, textSize.width + 2 * horizontal)
        let bubbleHeight = textSize.height + 2 * vertical
        let top: CGFloat = position.isFirst ? 10 : 2
        let x = trailing ? width - Self.sideInset - bubbleWidth : Self.sideInset
        let frame = CGRect(x: x, y: top, width: bubbleWidth, height: bubbleHeight)
        let textFrame = CGRect(x: frame.minX + horizontal, y: frame.minY + vertical,
                               width: bubbleWidth - 2 * horizontal, height: textSize.height)
        return AcpmuxRowLayout(height: top + bubbleHeight + (position.isLast ? 4 : 0), surfaceFrame: frame,
                               textFrame: textFrame, text: text, surface: surface, showsTail: position.isLast,
                               isToggleable: false, dimmed: dimmed, timestamp: timestamp)
    }

    private func plain(
        _ text: NSAttributedString,
        width: CGFloat,
        top: CGFloat,
        bottom: CGFloat,
        indent: CGFloat,
        toggleable: Bool,
        timestamp: String?
    ) -> AcpmuxRowLayout {
        let available = width - indent - Self.sideInset
        let size = measurer.size(of: text, width: available)
        let frame = CGRect(x: indent, y: top, width: available, height: size.height)
        return AcpmuxRowLayout(height: top + size.height + bottom, surfaceFrame: frame, textFrame: frame,
                               text: text, surface: .none, showsTail: false, isToggleable: toggleable,
                               dimmed: false, timestamp: timestamp)
    }

    private func card(_ text: NSAttributedString, width: CGFloat, timestamp: String?) -> AcpmuxRowLayout {
        let side = Self.sideInset
        let padding: CGFloat = 10
        let cardWidth = min(width - 2 * side, 640)
        let size = measurer.size(of: text, width: cardWidth - 2 * padding)
        let frame = CGRect(x: side, y: 6, width: cardWidth, height: size.height + 2 * padding)
        return AcpmuxRowLayout(height: frame.maxY + 6, surfaceFrame: frame,
                               textFrame: frame.insetBy(dx: padding, dy: padding), text: text, surface: .card,
                               showsTail: false, isToggleable: false, dimmed: false, timestamp: timestamp)
    }
}
