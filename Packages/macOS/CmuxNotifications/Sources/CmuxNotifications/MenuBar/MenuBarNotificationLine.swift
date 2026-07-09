public import Foundation
import AppKit

/// A single rendered notification line for the menu-bar status item.
///
/// Pure value type wrapping the ``TerminalNotification`` plus its owning tab
/// title and the menu's wrapping bounds. The derived titles are byte-faithful to
/// the legacy `MenuBarNotificationLineFormatter`: ``plainTitle`` joins a
/// read/unread dot, the title and short time, an optional body-or-subtitle
/// detail line, and an optional tab title; ``menuTitle`` word-wraps that text to
/// ``maxWidth`` using the menu font and truncates the last visible line with an
/// ellipsis once it exceeds ``maxLines``; ``attributedTitle`` renders
/// ``menuTitle`` in the menu font; ``tooltip`` is the unwrapped ``plainTitle``.
public struct MenuBarNotificationLine: Sendable {
    /// Default wrapping width applied to ``menuTitle``.
    public static let defaultMaxMenuTextWidth: CGFloat = 280
    /// Default visible-line cap applied to ``menuTitle``.
    public static let defaultMaxMenuTextLines = 3

    /// The notification rendered by this line.
    public var notification: TerminalNotification
    /// The owning tab's title, appended as a trailing line when present.
    public var tabTitle: String?
    /// The wrapping width used by ``menuTitle`` and ``attributedTitle``.
    public var maxWidth: CGFloat
    /// The visible-line cap used by ``menuTitle`` and ``attributedTitle``.
    public var maxLines: Int

    /// Creates a menu-bar line descriptor for the given notification.
    public init(
        notification: TerminalNotification,
        tabTitle: String?,
        maxWidth: CGFloat = defaultMaxMenuTextWidth,
        maxLines: Int = defaultMaxMenuTextLines
    ) {
        self.notification = notification
        self.tabTitle = tabTitle
        self.maxWidth = maxWidth
        self.maxLines = maxLines
    }

    /// The unwrapped multi-line title: dot + title + time, optional detail, optional tab.
    public var plainTitle: String {
        let dot = notification.isRead ? "  " : "● "
        let timeText = notification.createdAt.formatted(date: .omitted, time: .shortened)
        var lines: [String] = []
        lines.append("\(dot)\(notification.title)  \(timeText)")

        let detail = notification.body.isEmpty ? notification.subtitle : notification.body
        if !detail.isEmpty {
            lines.append(detail)
        }

        if let tabTitle, !tabTitle.isEmpty {
            lines.append(tabTitle)
        }

        return lines.joined(separator: "\n")
    }

    /// ``plainTitle`` word-wrapped to ``maxWidth`` and truncated to ``maxLines``.
    public var menuTitle: String {
        wrappedAndTruncated(plainTitle, maxWidth: maxWidth, maxLines: maxLines)
    }

    /// ``menuTitle`` rendered in the menu font with the label color.
    public var attributedTitle: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(
            string: menuTitle,
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )
    }

    /// The tooltip text, identical to the unwrapped ``plainTitle``.
    public var tooltip: String {
        plainTitle
    }

    private func wrappedAndTruncated(_ text: String, maxWidth: CGFloat, maxLines: Int) -> String {
        let width = max(60, maxWidth)
        let lines = max(1, maxLines)
        let font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        let wrapped = wrappedLines(for: text, maxWidth: width, font: font)
        guard wrapped.count > lines else { return wrapped.joined(separator: "\n") }

        var clipped = Array(wrapped.prefix(lines))
        clipped[lines - 1] = truncateLine(clipped[lines - 1], maxWidth: width, font: font)
        return clipped.joined(separator: "\n")
    }

    private func wrappedLines(for text: String, maxWidth: CGFloat, font: NSFont) -> [String] {
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: maxWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        _ = layout.glyphRange(for: container)

        let fullText = text as NSString
        var rows: [String] = []
        var glyphIndex = 0
        while glyphIndex < layout.numberOfGlyphs {
            var glyphRange = NSRange()
            layout.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &glyphRange)
            if glyphRange.length == 0 { break }

            let charRange = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let row = fullText.substring(with: charRange).trimmingCharacters(in: .newlines)
            rows.append(row)
            glyphIndex = NSMaxRange(glyphRange)
        }

        if rows.isEmpty {
            return [text]
        }
        return rows
    }

    private func truncateLine(_ line: String, maxWidth: CGFloat, font: NSFont) -> String {
        let ellipsis = "…"
        let full = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if full.isEmpty { return ellipsis }

        if measuredWidth(full + ellipsis, font: font) <= maxWidth {
            return full + ellipsis
        }

        var chars = Array(full)
        while !chars.isEmpty {
            chars.removeLast()
            let candidateBase = String(chars).trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = (candidateBase.isEmpty ? "" : candidateBase) + ellipsis
            if measuredWidth(candidate, font: font) <= maxWidth {
                return candidate
            }
        }
        return ellipsis
    }

    private func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}
