import AppKit

extension FilePreviewTextEditor {
    static func applyTheme(
        to scrollView: NSScrollView,
        backgroundColor: NSColor,
        foregroundColor: NSColor,
        drawsBackground: Bool
    ) {
        let resolvedBackgroundColor = drawsBackground ? backgroundColor : .clear
        scrollView.drawsBackground = drawsBackground
        scrollView.backgroundColor = resolvedBackgroundColor
        scrollView.contentView.drawsBackground = drawsBackground
        scrollView.contentView.backgroundColor = resolvedBackgroundColor
        if let textView = scrollView.documentView as? NSTextView {
            textView.drawsBackground = drawsBackground
            textView.backgroundColor = resolvedBackgroundColor
            textView.textColor = foregroundColor
            // Accent caret: the theme-foreground caret reads as a stray gray
            // line against dark note backgrounds rather than a cursor.
            textView.insertionPointColor = .controlAccentColor
            if let savingTextView = textView as? SavingTextView {
                savingTextView.currentLineHighlightColor = foregroundColor.withAlphaComponent(0.055)
            }
        }
        Self.updateLineNumberRulerTheme(
            on: scrollView,
            backgroundColor: resolvedBackgroundColor,
            foregroundColor: foregroundColor
        )
    }
}
