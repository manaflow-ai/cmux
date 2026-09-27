import AppKit
import CmuxBrowser

/// Splits a composer deletion around authoritative context-token attachments.
enum BrowserDesignModeTokenDeletion {
    static func textRangesOutsideAttachments(
        in content: NSAttributedString,
        range: NSRange
    ) -> [NSRange] {
        let validRange = NSIntersectionRange(
            range,
            NSRange(location: 0, length: content.length)
        )
        guard validRange.length > 0 else { return [] }
        var textRanges: [NSRange] = []
        var cursor = validRange.location
        content.enumerateAttribute(.attachment, in: validRange) { value, attachmentRange, _ in
            guard value != nil else { return }
            if cursor < attachmentRange.location {
                textRanges.append(NSRange(location: cursor, length: attachmentRange.location - cursor))
            }
            cursor = max(cursor, attachmentRange.upperBound)
        }
        if cursor < validRange.upperBound {
            textRanges.append(NSRange(location: cursor, length: validRange.upperBound - cursor))
        }
        return textRanges
    }
}

/// Draws a context token with a stable leading column that becomes a delete affordance on hover.
final class BrowserDesignModeTokenCell: NSTextAttachmentCell {
    let identity: String
    private let tagTitle: String
    private let icon: NSImage?
    private let deleteIcon: NSImage?
    private let titleAttributes: [NSAttributedString.Key: Any]
    private let onRemove: @MainActor (String) -> Void

    /// Parses the runtime's palette hex (#RRGGBB); falls back to accent blue.
    private static func tintColor(fromHex hex: String) -> NSColor {
        var value: UInt64 = 0
        let trimmed = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard trimmed.count == 6, Scanner(string: trimmed).scanHexInt64(&value) else {
            return BrowserDesignModeTokenStyle.blue
        }
        return NSColor(
            calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    init(
        selection: BrowserDesignModeSelection,
        onRemove: @escaping @MainActor (String) -> Void
    ) {
        identity = selection.selector
        tagTitle = selection.tagName
        self.onRemove = onRemove
        let tint = Self.tintColor(fromHex: selection.color)
        titleAttributes = [
            // Same point size as the typed text so pills read as inline words;
            // medium weight alone marks them as tags.
            .font: NSFont.systemFont(ofSize: 13.5, weight: .medium),
            .foregroundColor: tint,
        ]
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        let symbol = NSImage(
            systemSymbolName: BrowserDesignModeTagSymbol.symbol(forTag: selection.tagName),
            accessibilityDescription: selection.tagName
        )?.withSymbolConfiguration(configuration)
        let removeSymbol = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration)
        // Tint once; draw(withFrame:in:) runs on every text-view redraw.
        let tintImage: (NSImage?) -> NSImage? = { source in
            source.map { base in
                NSImage(size: base.size, flipped: false) { rect in
                    base.draw(in: rect)
                    tint.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
            }
        }
        icon = tintImage(symbol)
        deleteIcon = tintImage(removeSymbol)
        super.init(textCell: "")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(
            String(
                localized: "browser.designMode.context.remove",
                defaultValue: "Remove \(selection.tagName) context"
            )
        )
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("unsupported") }

    func performRemoval() {
        onRemove(identity)
    }

    func deleteHitRect(in cellFrame: NSRect) -> NSRect {
        NSRect(x: cellFrame.minX + 3, y: cellFrame.minY, width: 19, height: cellFrame.height)
    }

    override func accessibilityPerformPress() -> Bool {
        performRemoval()
        return true
    }

    private var titleSize: NSSize {
        (tagTitle as NSString).size(withAttributes: titleAttributes)
    }

    override func cellSize() -> NSSize {
        // Reserve a stable leading glyph column so hover never reflows text.
        let iconWidth: CGFloat = icon == nil && deleteIcon == nil ? 0 : 13
        return NSSize(
            width: titleSize.width + iconWidth + 16,
            height: BrowserDesignModeTokenStyle.naturalLineHeight
        )
    }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: BrowserDesignModeTokenStyle.font.descender)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let baseline = cellFrame.minY + cellFrame.height
            + BrowserDesignModeTokenStyle.font.descender
        let titleFont = titleAttributes[.font] as? NSFont
            ?? BrowserDesignModeTokenStyle.font
        let hovering = (controlView as? BrowserDesignModeTokenTextView)?.hoveredTokenIdentity == identity
        var textX = cellFrame.minX + 8
        if let leadingIcon = hovering ? deleteIcon : icon {
            let iconRect = NSRect(
                x: textX,
                y: baseline - titleFont.capHeight / 2 - leadingIcon.size.height / 2,
                width: leadingIcon.size.width,
                height: leadingIcon.size.height
            )
            leadingIcon.draw(in: iconRect)
            textX = iconRect.maxX + 3
        }
        (tagTitle as NSString).draw(
            at: NSPoint(x: textX, y: baseline - titleFont.ascender),
            withAttributes: titleAttributes
        )
    }
}
