import CmuxHomeRender
import CoreGraphics
import CoreText
import Foundation

/// Where each item of a chat widget card sits for one bubble width (HomeWidgetRowProvider):
/// pure, so the row measures and draws off the main thread and a click maps to the same frames.
struct HomeWidgetLayout {
    static let maxWidth: CGFloat = 340
    static let padX: CGFloat = 12
    static let padY: CGFloat = 10
    static let spacing: CGFloat = 6
    static let rowHeight: CGFloat = 34
    static let buttonHeight: CGFloat = 28
    static let badgeHeight: CGFloat = 20
    static let maxTextLines = 4

    /// One placed item: its frame in the body (top-left origin) and, for text, its lines.
    struct Placed {
        var item: HomeWidgetItem
        var frame: CGRect
        var lines: [CTLine] = []
        /// Button frames of a buttons item, with their nodes.
        var buttons: [(button: HomeWidgetButton, frame: CGRect)] = []
    }

    let size: CGSize
    let placed: [Placed]

    init(_ snapshot: HomeWidgetSnapshot, width maxWidth: CGFloat) {
        let width = max(120, min(Self.maxWidth, maxWidth))
        let inner = width - 2 * Self.padX
        var y = Self.padY
        var out: [Placed] = []
        for item in snapshot.items.prefix(HomeWidgetSnapshot.maxItems) {
            if !out.isEmpty { y += Self.spacing }
            var placed = Placed(item: item, frame: .zero)
            let height: CGFloat
            switch item {
            case let .text(text, style, _):
                let font = HomeWidgetStyle.font(style)
                placed.lines = Self.wrap(text, font: font, width: inner, maxLines: Self.maxTextLines)
                height = CGFloat(max(1, placed.lines.count)) * HomeWidgetStyle.lineHeight(style)
            case .row:
                height = Self.rowHeight
            case let .buttons(buttons):
                height = buttons.isEmpty ? 0 : Self.buttonHeight
                let gap: CGFloat = 8
                let each = buttons.isEmpty ? 0 : (inner - gap * CGFloat(buttons.count - 1)) / CGFloat(buttons.count)
                placed.buttons = buttons.enumerated().map { index, button in
                    (button, CGRect(x: Self.padX + CGFloat(index) * (each + gap), y: y, width: each, height: Self.buttonHeight))
                }
            case let .badge(text, _):
                height = Self.badgeHeight
                let w = min(inner, TextDraw.width(text, font: HomeWidgetStyle.badgeFont) + 16)
                placed.frame = CGRect(x: Self.padX, y: y, width: w, height: height)
            case .divider:
                height = 1
            case let .empty(_, message, _):
                height = message == nil ? 52 : 68
            }
            if case .badge = item {} else { placed.frame = CGRect(x: Self.padX, y: y, width: inner, height: height) }
            out.append(placed)
            y += height
        }
        size = CGSize(width: width, height: (out.isEmpty ? 2 * Self.padY : y + Self.padY).rounded(.up))
        placed = out
    }

    /// The scene node a click at `point` (body coordinates) lands on: a clickable row or an
    /// enabled button.
    func node(at point: CGPoint) -> String? {
        for item in placed {
            switch item.item {
            case let .row(node, _, _, _, _, _) where item.frame.contains(point):
                return node
            case .buttons:
                if let hit = item.buttons.first(where: { $0.button.enabled && $0.frame.contains(point) }) { return hit.button.node }
            default:
                continue
            }
        }
        return nil
    }

    /// `text` broken into at most `maxLines` lines of `width`, the last one truncated with an ellipsis.
    static func wrap(_ text: String, font: UIFont, width: CGFloat, maxLines: Int) -> [CTLine] {
        // The color comes from the context at draw time (the item's tint).
        let fromContext = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)
        let attributed = NSAttributedString(string: text, attributes: [.font: font, fromContext: true])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = attributed.length
        var lines: [CTLine] = []
        var start = 0
        while start < length, lines.count < maxLines {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            guard count > 0 else { break }
            if lines.count == maxLines - 1, start + count < length {
                let rest = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: length - start))
                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: [.font: font, fromContext: true]))
                lines.append(CTLineCreateTruncatedLine(rest, Double(width), .end, ellipsis) ?? rest)
                break
            }
            lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
            start += count
        }
        return lines
    }
}
